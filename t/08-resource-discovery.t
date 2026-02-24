use strict;
use warnings;
use Test::More;
use JSON::MaybeXS;

use MCP::K8s;

# =================================================================
# Mock API that returns discovery endpoint responses
# =================================================================

{
  package MockDiscoveryAPI;
  use JSON::MaybeXS;

  my $json = JSON::MaybeXS->new(utf8 => 1);

  sub new { bless { calls => [] }, shift }

  sub new_object {
    my ($self, $kind, $args) = @_;
    if ($kind eq 'SelfSubjectRulesReview') {
      return MockSSRR->new($args->{spec}{namespace});
    }
    return MockObj->new(kind => $kind, metadata => $args->{metadata} || {});
  }

  sub create {
    my ($self, $obj) = @_;
    return $obj;
  }

  sub list {
    my ($self, $kind, %args) = @_;
    return MockList->new();
  }

  sub expand_class {
    my ($self, $kind) = @_;
    # Simulate that most classes don't have resource_plural
    return undef;
  }

  sub _request {
    my ($self, $method, $path, $body, %opts) = @_;
    push @{ $self->{calls} }, $path;

    if ($path eq '/api/v1') {
      my $body = $json->encode({
        kind => 'APIResourceList',
        resources => [
          { name => 'pods', kind => 'Pod', namespaced => 1, verbs => ['get', 'list'] },
          { name => 'services', kind => 'Service', namespaced => 1, verbs => ['get', 'list'] },
          { name => 'configmaps', kind => 'ConfigMap', namespaced => 1, verbs => ['get', 'list'] },
          { name => 'pods/log', kind => 'Pod', namespaced => 1, verbs => ['get'] },  # subresource
          { name => 'customwidgets', kind => 'CustomWidget', namespaced => 1, verbs => ['get', 'list'] },
        ],
      });
      return MockHTTPResp->new(200, $body);
    }
    elsif ($path eq '/apis') {
      my $body = $json->encode({
        kind => 'APIGroupList',
        groups => [
          {
            name => 'cilium.io',
            preferredVersion => { groupVersion => 'cilium.io/v2' },
          },
        ],
      });
      return MockHTTPResp->new(200, $body);
    }
    elsif ($path eq '/apis/cilium.io/v2') {
      my $body = $json->encode({
        kind => 'APIResourceList',
        resources => [
          { name => 'ciliumnetworkpolicies', kind => 'CiliumNetworkPolicy', namespaced => 1, verbs => ['get', 'list'] },
          { name => 'ciliumendpoints', kind => 'CiliumEndpoint', namespaced => 1, verbs => ['get', 'list'] },
        ],
      });
      return MockHTTPResp->new(200, $body);
    }
    else {
      return MockHTTPResp->new(404, '{}');
    }
  }
}

{
  package MockHTTPResp;
  sub new {
    my ($class, $status, $content) = @_;
    bless { status => $status, content => $content }, $class;
  }
  sub status  { $_[0]->{status} }
  sub content { $_[0]->{content} }
}

{
  package MockSSRR;
  sub new {
    my ($class, $namespace) = @_;
    bless { namespace => $namespace // '' }, $class;
  }
  sub status {
    my ($self) = @_;
    return MockSSRRStatus->new($self->{namespace});
  }
}

{
  package MockSSRRStatus;
  sub new {
    my ($class, $namespace) = @_;
    my @rules;
    if ($namespace eq 'test-ns') {
      @rules = (MockRule->new(['get', 'list'], ['pods', 'services', 'events']));
    } elsif ($namespace eq '') {
      @rules = (MockRule->new(['list'], ['namespaces']));
    }
    bless { rules => \@rules }, $class;
  }
  sub resourceRules { $_[0]->{rules} }
}

{
  package MockRule;
  sub new {
    my ($class, $verbs, $resources) = @_;
    bless { verbs => $verbs, resources => $resources }, $class;
  }
  sub verbs     { $_[0]->{verbs} }
  sub resources { $_[0]->{resources} }
}

{
  package MockObj;
  sub new {
    my ($class, %args) = @_;
    bless \%args, $class;
  }
  sub kind     { $_[0]->{kind} }
  sub metadata { MockMeta->new(%{ $_[0]->{metadata} || {} }) }
  sub status   { undef }
  sub spec     { undef }
  sub can {
    my ($self, $method) = @_;
    return $self->SUPER::can($method) if $method =~ /^(metadata|kind|status|spec)$/;
    return $self->SUPER::can($method);
  }
}

{
  package MockMeta;
  sub new { bless { @_[1..$#_] }, $_[0] }
  sub name              { $_[0]->{name} }
  sub namespace         { $_[0]->{namespace} }
  sub labels            { undef }
  sub creationTimestamp  { undef }
  sub can {
    my ($self, $method) = @_;
    return $self->SUPER::can($method) if $method =~ /^(name|namespace|labels|creationTimestamp)$/;
    return $self->SUPER::can($method);
  }
}

{
  package MockList;
  sub new { bless { items => [] }, $_[0] }
  sub items { $_[0]->{items} }
}

# =================================================================
# Tests
# =================================================================

my $api = MockDiscoveryAPI->new;
my $k8s = MCP::K8s->new(
  api        => $api,
  namespaces => ['test-ns'],
);

subtest 'static map takes priority' => sub {
  # Pod is in %RESOURCE_PLURALS, should not trigger discovery
  is($k8s->_resource_plural('Pod'), 'pods', 'Pod resolved from static map');
  is($k8s->_resource_plural('Deployment'), 'deployments', 'Deployment resolved from static map');
  is($k8s->_resource_plural('Ingress'), 'ingresses', 'Ingress resolved from static map');
};

subtest 'discovery populates cache for unknown kinds' => sub {
  # CustomWidget is NOT in the static map, should trigger API discovery
  my $plural = $k8s->_resource_plural('CustomWidget');
  is($plural, 'customwidgets', 'CustomWidget resolved via API discovery');

  # Verify discovery was called
  my @discovery_calls = grep { m{^/api} } @{ $api->{calls} };
  ok(scalar @discovery_calls > 0, 'API discovery endpoints were called');
};

subtest 'CRD kinds resolved via discovery' => sub {
  # CiliumNetworkPolicy from the cilium.io group
  my $plural = $k8s->_resource_plural('CiliumNetworkPolicy');
  is($plural, 'ciliumnetworkpolicies', 'CiliumNetworkPolicy resolved via API group discovery');

  my $plural2 = $k8s->_resource_plural('CiliumEndpoint');
  is($plural2, 'ciliumendpoints', 'CiliumEndpoint resolved via API group discovery');
};

subtest 'cache is populated after first discovery' => sub {
  my $cache = $k8s->_resource_plurals_cache;
  ok(keys %$cache > 0, 'cache has entries after discovery');
  is($cache->{'CustomWidget'}, 'customwidgets', 'CustomWidget in cache');
  is($cache->{'CiliumNetworkPolicy'}, 'ciliumnetworkpolicies', 'CiliumNetworkPolicy in cache');
  is($cache->{'Service'}, 'services', 'Service in cache (from /api/v1)');
};

subtest 'subresources excluded from cache' => sub {
  my $cache = $k8s->_resource_plurals_cache;
  # pods/log is a subresource and should not create a cache entry
  ok(!exists $cache->{'pods/log'}, 'subresource pods/log not in cache');
};

subtest 'heuristic fallback for truly unknown kinds' => sub {
  # Something not in static map, not in IO::K8s, not from API discovery
  my $plural = $k8s->_resource_plural('ZzzzUnknownThing');
  is($plural, 'zzzzunknownthings', 'unknown kind falls back to heuristic');
};

subtest 'discovery called only once (cached)' => sub {
  my $call_count_before = scalar @{ $api->{calls} };

  # These should all use cache, no new API calls
  $k8s->_resource_plural('CustomWidget');
  $k8s->_resource_plural('CiliumNetworkPolicy');
  $k8s->_resource_plural('Service');

  my $call_count_after = scalar @{ $api->{calls} };
  is($call_count_after, $call_count_before, 'no additional API calls after cache populated');
};

done_testing;
