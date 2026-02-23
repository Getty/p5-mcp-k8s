use strict;
use warnings;
use Test::More;

use MCP::K8s::Permissions;

# =================================================================
# Mock infrastructure
# =================================================================

{
  package MockAPI;
  sub new { bless {}, shift }
  sub new_object {
    my ($self, $kind, $args) = @_;
    return MockReview->new($args->{spec}{namespace});
  }
  sub create {
    my ($self, $review) = @_;
    return $review;
  }
  sub expand_class { 'IO::K8s::Api::Authorization::V1::SelfSubjectRulesReview' }
}

{
  package MockReview;
  sub new {
    my ($class, $namespace) = @_;
    bless { namespace => $namespace }, $class;
  }
  sub status {
    my ($self) = @_;
    return MockStatus->new($self->{namespace});
  }
}

{
  package MockStatus;
  sub new {
    my ($class, $namespace) = @_;
    my $rules = _rules_for($namespace);
    bless { rules => $rules }, $class;
  }
  sub resourceRules { $_[0]->{rules} }

  sub _rules_for {
    my ($namespace) = @_;
    if ($namespace eq 'default') {
      return [
        MockRule->new(['get', 'list', 'watch'], ['pods', 'services', 'deployments']),
        MockRule->new(['get'], ['pods/log']),
        MockRule->new(['create', 'delete'], ['configmaps']),
      ];
    } elsif ($namespace eq 'admin') {
      return [
        MockRule->new(['*'], ['*']),
      ];
    } elsif ($namespace eq 'readonly') {
      return [
        MockRule->new(['get', 'list'], ['pods', 'services']),
      ];
    } elsif ($namespace eq 'deployer') {
      return [
        MockRule->new(['get', 'list', 'watch'], ['pods', 'deployments', 'replicasets']),
        MockRule->new(['update', 'patch'], ['deployments']),
        MockRule->new(['create'], ['pods']),
        MockRule->new(['get'], ['pods/log']),
      ];
    } elsif ($namespace eq 'wildcard-verb') {
      return [
        MockRule->new(['*'], ['configmaps', 'secrets']),
      ];
    } elsif ($namespace eq 'empty') {
      return [];
    } elsif ($namespace eq '') {
      return [
        MockRule->new(['list'], ['namespaces']),
        MockRule->new(['get'], ['nodes']),
      ];
    }
    return [];
  }
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

# Helper: create Permissions with strong API ref kept alive
sub make_perms {
  my (@namespaces) = @_;
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => \@namespaces,
  );
  $perms->discover;
  # Return both to keep $api alive (weak_ref in Permissions)
  return ($perms, $api);
}

# =================================================================
# Tests
# =================================================================

subtest 'basic permission discovery' => sub {
  my ($perms, $api) = make_perms('default');

  # Explicit grants
  ok($perms->can_do('list', 'pods', 'default'), 'can list pods');
  ok($perms->can_do('get', 'pods', 'default'), 'can get pods');
  ok($perms->can_do('watch', 'services', 'default'), 'can watch services');
  ok($perms->can_do('get', 'deployments', 'default'), 'can get deployments');
  ok($perms->can_do('create', 'configmaps', 'default'), 'can create configmaps');
  ok($perms->can_do('delete', 'configmaps', 'default'), 'can delete configmaps');

  # Not granted
  ok(!$perms->can_do('create', 'pods', 'default'), 'cannot create pods');
  ok(!$perms->can_do('delete', 'pods', 'default'), 'cannot delete pods');
  ok(!$perms->can_do('patch', 'pods', 'default'), 'cannot patch pods');
  ok(!$perms->can_do('update', 'services', 'default'), 'cannot update services');
  ok(!$perms->can_do('list', 'secrets', 'default'), 'cannot list secrets');
  ok(!$perms->can_do('create', 'deployments', 'default'), 'cannot create deployments');
};

subtest 'wildcard resource (*) permissions' => sub {
  my ($perms, $api) = make_perms('admin');

  ok($perms->can_do('get', 'pods', 'admin'), 'wildcard: get pods');
  ok($perms->can_do('list', 'pods', 'admin'), 'wildcard: list pods');
  ok($perms->can_do('create', 'deployments', 'admin'), 'wildcard: create deployments');
  ok($perms->can_do('delete', 'secrets', 'admin'), 'wildcard: delete secrets');
  ok($perms->can_do('patch', 'anything', 'admin'), 'wildcard: patch anything');
  ok($perms->can_do('watch', 'customresource', 'admin'), 'wildcard: watch unknown resource');
  ok($perms->can_do('update', 'nodes', 'admin'), 'wildcard: update nodes');
};

subtest 'wildcard verb (*) on specific resources' => sub {
  my ($perms, $api) = make_perms('wildcard-verb');

  ok($perms->can_do('get', 'configmaps', 'wildcard-verb'), 'verb wildcard: get configmaps');
  ok($perms->can_do('list', 'configmaps', 'wildcard-verb'), 'verb wildcard: list configmaps');
  ok($perms->can_do('create', 'configmaps', 'wildcard-verb'), 'verb wildcard: create configmaps');
  ok($perms->can_do('delete', 'configmaps', 'wildcard-verb'), 'verb wildcard: delete configmaps');
  ok($perms->can_do('patch', 'secrets', 'wildcard-verb'), 'verb wildcard: patch secrets');

  ok(!$perms->can_do('list', 'pods', 'wildcard-verb'), 'verb wildcard: cannot list pods');
};

subtest 'deployer role (mixed permissions)' => sub {
  my ($perms, $api) = make_perms('deployer');

  # Read access
  ok($perms->can_do('get', 'pods', 'deployer'), 'deployer: get pods');
  ok($perms->can_do('list', 'deployments', 'deployer'), 'deployer: list deployments');
  ok($perms->can_do('watch', 'replicasets', 'deployer'), 'deployer: watch replicasets');

  # Write access (specific)
  ok($perms->can_do('update', 'deployments', 'deployer'), 'deployer: update deployments');
  ok($perms->can_do('patch', 'deployments', 'deployer'), 'deployer: patch deployments');
  ok($perms->can_do('create', 'pods', 'deployer'), 'deployer: create pods');

  # Not granted
  ok(!$perms->can_do('delete', 'pods', 'deployer'), 'deployer: cannot delete pods');
  ok(!$perms->can_do('create', 'services', 'deployer'), 'deployer: cannot create services');
  ok(!$perms->can_do('update', 'pods', 'deployer'), 'deployer: cannot update pods');
};

subtest 'cluster-scoped permissions' => sub {
  my ($perms, $api) = make_perms('default');

  ok($perms->can_do('list', 'namespaces', ''), 'cluster: list namespaces');
  ok($perms->can_do('get', 'nodes', ''), 'cluster: get nodes');
  ok(!$perms->can_do('create', 'namespaces', ''), 'cluster: cannot create namespaces');
  ok(!$perms->can_do('delete', 'nodes', ''), 'cluster: cannot delete nodes');
};

subtest 'unknown namespace denied' => sub {
  my ($perms, $api) = make_perms('default');

  ok(!$perms->can_do('list', 'pods', 'nonexistent'), 'unknown ns: denied');
  ok(!$perms->can_do('get', 'pods', 'production'), 'undiscovered ns: denied');
};

subtest 'empty namespace (no rules)' => sub {
  my ($perms, $api) = make_perms('empty');

  ok(!$perms->can_do('list', 'pods', 'empty'), 'empty: no list');
  ok(!$perms->can_do('get', 'pods', 'empty'), 'empty: no get');
};

subtest 'allowed_namespaces' => sub {
  my ($perms, $api) = make_perms('default', 'admin', 'readonly');

  my @ns = $perms->allowed_namespaces;
  is_deeply([sort @ns], ['admin', 'default', 'readonly'],
    'all three namespaces discovered');
};

subtest 'allowed_namespaces excludes empty results' => sub {
  my ($perms, $api) = make_perms('default', 'empty');

  my @ns = $perms->allowed_namespaces;
  is_deeply(\@ns, ['default'], 'empty namespace excluded');
};

subtest 'allowed_resources for list' => sub {
  my ($perms, $api) = make_perms('default');

  my @resources = $perms->allowed_resources('list', 'default');
  ok((grep { $_ eq 'pods' } @resources), 'pods listable');
  ok((grep { $_ eq 'services' } @resources), 'services listable');
  ok((grep { $_ eq 'deployments' } @resources), 'deployments listable');
  ok(!(grep { $_ eq 'configmaps' } @resources), 'configmaps NOT listable');
  ok(!(grep { $_ eq 'secrets' } @resources), 'secrets NOT listable');
};

subtest 'allowed_resources for create' => sub {
  my ($perms, $api) = make_perms('default');

  my @resources = $perms->allowed_resources('create', 'default');
  ok((grep { $_ eq 'configmaps' } @resources), 'configmaps creatable');
  ok(!(grep { $_ eq 'pods' } @resources), 'pods NOT creatable');
  ok(!(grep { $_ eq 'deployments' } @resources), 'deployments NOT creatable');
};

subtest 'allowed_resources with wildcard' => sub {
  my ($perms, $api) = make_perms('admin');

  my @resources = $perms->allowed_resources('list', 'admin');
  ok((grep { $_ eq '*' } @resources), 'wildcard in allowed resources');
};

subtest 'allowed_resources excludes subresources' => sub {
  my ($perms, $api) = make_perms('default');

  my @resources = $perms->allowed_resources('get', 'default');
  ok(!(grep { $_ eq 'pods/log' } @resources), 'pods/log excluded from resource list');
  ok((grep { $_ eq 'pods' } @resources), 'pods still included');
};

subtest 'can_read_logs - explicit pods/log permission' => sub {
  my ($perms, $api) = make_perms('default');
  ok($perms->can_read_logs('default'), 'logs via pods/log permission');
};

subtest 'can_read_logs - wildcard resource' => sub {
  my ($perms, $api) = make_perms('admin');
  ok($perms->can_read_logs('admin'), 'logs via wildcard resource');
};

subtest 'can_read_logs - pods get implies logs' => sub {
  my ($perms, $api) = make_perms('readonly');
  ok($perms->can_read_logs('readonly'), 'logs via pods get permission');
};

subtest 'can_read_logs denied' => sub {
  my ($perms, $api) = make_perms('empty');

  ok(!$perms->can_read_logs('empty'), 'no log access in empty ns');
  ok(!$perms->can_read_logs('nonexistent'), 'no log access in unknown ns');
};

subtest 'discover returns self for chaining' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['default'],
  );
  my $ret = $perms->discover;
  is($ret, $perms, 'discover returns $self');
};

subtest 'summary - basic structure' => sub {
  my ($perms, $api) = make_perms('default', 'admin');

  my $summary = $perms->summary;
  ok(length($summary) > 0, 'summary is not empty');
  like($summary, qr/# Kubernetes RBAC Permissions/, 'has title');
  like($summary, qr/## Namespace: default/, 'has default namespace section');
  like($summary, qr/## Namespace: admin/, 'has admin namespace section');
};

subtest 'summary - read-only namespace' => sub {
  my ($perms, $api) = make_perms('default');

  my $summary = $perms->summary;
  like($summary, qr/\*\*get\*\*/, 'summary lists get verb');
  like($summary, qr/\*\*list\*\*/, 'summary lists list verb');
  like($summary, qr/pods/, 'summary mentions pods');
  like($summary, qr/services/, 'summary mentions services');
};

subtest 'summary - full access namespace' => sub {
  my ($perms, $api) = make_perms('admin');

  my $summary = $perms->summary;
  like($summary, qr/Full access/, 'admin shows full access');
};

subtest 'summary - cluster-scoped' => sub {
  my ($perms, $api) = make_perms('default');

  my $summary = $perms->summary;
  like($summary, qr/Cluster-scoped/, 'summary has cluster section');
  like($summary, qr/namespaces/, 'cluster section mentions namespaces');
};

subtest 'summary - no permissions' => sub {
  my ($perms, $api) = make_perms('empty');

  my $summary = $perms->summary;
  like($summary, qr/No namespace permissions discovered/, 'shows no-permissions message');
};

subtest 'multiple namespace cross-isolation' => sub {
  my ($perms, $api) = make_perms('default', 'deployer');

  ok($perms->can_do('list', 'pods', 'default'), 'default: list pods');
  ok(!$perms->can_do('create', 'pods', 'default'), 'default: no create pods');

  ok($perms->can_do('create', 'pods', 'deployer'), 'deployer: create pods');
  ok(!$perms->can_do('delete', 'pods', 'deployer'), 'deployer: no delete pods');

  ok(!$perms->can_do('patch', 'deployments', 'default'), 'default: no patch deployments');
  ok($perms->can_do('patch', 'deployments', 'deployer'), 'deployer: patch deployments');
};

done_testing;
