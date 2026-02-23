use strict;
use warnings;
use Test::More;

use MCP::K8s;
use MCP::K8s::Permissions;

# =================================================================
# Mock infrastructure
# =================================================================

{
  package MockAPI3;
  sub new { bless {}, shift }
  sub new_object {
    my ($self, $kind, $args) = @_;
    return MockReview3->new($args->{spec}{namespace});
  }
  sub create {
    my ($self, $review) = @_;
    return $review;
  }
  sub expand_class { 'IO::K8s::Api::Authorization::V1::SelfSubjectRulesReview' }
}

{
  package MockReview3;
  sub new {
    my ($class, $namespace) = @_;
    bless { namespace => $namespace }, $class;
  }
  sub status {
    my ($self) = @_;
    return MockStatus3->new($self->{namespace});
  }
}

{
  package MockStatus3;
  sub new {
    my ($class, $namespace) = @_;
    my @rules;
    if ($namespace eq 'only-ns' || $namespace eq 'first' || $namespace eq 'second') {
      @rules = (MockRule3->new(['get', 'list'], ['pods']));
    } elsif ($namespace eq '') {
      @rules = (MockRule3->new(['list'], ['namespaces']));
    }
    bless { rules => \@rules }, $class;
  }
  sub resourceRules { $_[0]->{rules} }
}

{
  package MockRule3;
  sub new {
    my ($class, $verbs, $resources) = @_;
    bless { verbs => $verbs, resources => $resources }, $class;
  }
  sub verbs     { $_[0]->{verbs} }
  sub resources { $_[0]->{resources} }
}

# =================================================================
# Helper
# =================================================================

sub make_k8s_with_namespaces {
  my (@namespaces) = @_;
  my $api = MockAPI3->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => \@namespaces,
  );
  $perms->discover;

  # Keep $api alive alongside the K8s object
  my $k8s = bless { permissions => $perms, _api_ref => $api }, 'MCP::K8s';
  return $k8s;
}

# =================================================================
# Tests
# =================================================================

subtest 'explicit namespace always used' => sub {
  my $k8s = make_k8s_with_namespaces('first', 'second');

  my $ns = $k8s->_resolve_namespace({ namespace => 'explicit' });
  is($ns, 'explicit', 'explicit namespace returned as-is');
};

subtest 'single namespace auto-fills' => sub {
  my $k8s = make_k8s_with_namespaces('only-ns');

  my $ns = $k8s->_resolve_namespace({});
  is($ns, 'only-ns', 'auto-fills when only one namespace');
};

subtest 'multiple namespaces return undef' => sub {
  my $k8s = make_k8s_with_namespaces('first', 'second');

  my $ns = $k8s->_resolve_namespace({});
  is($ns, undef, 'undef when multiple namespaces and none specified');
};

subtest 'empty string namespace not treated as provided' => sub {
  my $k8s = make_k8s_with_namespaces('only-ns');

  my $ns = $k8s->_resolve_namespace({ namespace => '' });
  is($ns, 'only-ns', 'empty string triggers auto-fill');
};

subtest 'undef namespace triggers auto-fill' => sub {
  my $k8s = make_k8s_with_namespaces('only-ns');

  my $ns = $k8s->_resolve_namespace({ namespace => undef });
  is($ns, 'only-ns', 'undef triggers auto-fill');
};

done_testing;
