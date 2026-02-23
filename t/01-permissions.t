use strict;
use warnings;
use Test::More;

use MCP::K8s::Permissions;

# Mock API object that doesn't actually connect
{
  package MockAPI;
  sub new { bless {}, shift }
  sub new_object {
    my ($self, $kind, $args) = @_;
    return MockReview->new($args->{spec}{namespace});
  }
  sub create {
    my ($self, $review) = @_;
    return $review;  # MockReview already has the response built in
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
    } elsif ($namespace eq '') {
      return [
        MockRule->new(['list'], ['namespaces']),
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

# Test basic permission discovery
subtest 'discover permissions' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['default', 'admin'],
  );
  $perms->discover;

  ok($perms->can_do('list', 'pods', 'default'), 'can list pods in default');
  ok($perms->can_do('get', 'pods', 'default'), 'can get pods in default');
  ok($perms->can_do('watch', 'services', 'default'), 'can watch services in default');
  ok(!$perms->can_do('create', 'pods', 'default'), 'cannot create pods in default');
  ok(!$perms->can_do('delete', 'pods', 'default'), 'cannot delete pods in default');
  ok($perms->can_do('create', 'configmaps', 'default'), 'can create configmaps in default');
  ok($perms->can_do('delete', 'configmaps', 'default'), 'can delete configmaps in default');
};

subtest 'wildcard permissions' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['admin'],
  );
  $perms->discover;

  ok($perms->can_do('get', 'pods', 'admin'), 'wildcard: can get pods');
  ok($perms->can_do('list', 'pods', 'admin'), 'wildcard: can list pods');
  ok($perms->can_do('create', 'deployments', 'admin'), 'wildcard: can create deployments');
  ok($perms->can_do('delete', 'secrets', 'admin'), 'wildcard: can delete secrets');
  ok($perms->can_do('patch', 'anything', 'admin'), 'wildcard: can patch anything');
};

subtest 'allowed_namespaces' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['default', 'admin'],
  );
  $perms->discover;

  my @ns = $perms->allowed_namespaces;
  is_deeply([sort @ns], ['admin', 'default'], 'both namespaces allowed');
};

subtest 'allowed_resources' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['default'],
  );
  $perms->discover;

  my @list_resources = $perms->allowed_resources('list', 'default');
  ok((grep { $_ eq 'pods' } @list_resources), 'pods in list resources');
  ok((grep { $_ eq 'services' } @list_resources), 'services in list resources');
  ok((grep { $_ eq 'deployments' } @list_resources), 'deployments in list resources');

  my @create_resources = $perms->allowed_resources('create', 'default');
  ok((grep { $_ eq 'configmaps' } @create_resources), 'configmaps in create resources');
  ok(!(grep { $_ eq 'pods' } @create_resources), 'pods NOT in create resources');
};

subtest 'can_read_logs' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['default', 'admin'],
  );
  $perms->discover;

  ok($perms->can_read_logs('default'), 'can read logs in default (pods/log permission)');
  ok($perms->can_read_logs('admin'), 'can read logs in admin (wildcard permission)');
};

subtest 'cluster-scoped permissions' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['default'],
  );
  $perms->discover;

  ok($perms->can_do('list', 'namespaces', ''), 'can list namespaces cluster-scoped');
  ok(!$perms->can_do('create', 'namespaces', ''), 'cannot create namespaces cluster-scoped');
};

subtest 'permission denied for unknown namespace' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['default'],
  );
  $perms->discover;

  ok(!$perms->can_do('list', 'pods', 'nonexistent'), 'no permissions in unknown namespace');
};

subtest 'summary output' => sub {
  my $api = MockAPI->new;
  my $perms = MCP::K8s::Permissions->new(
    api        => $api,
    namespaces => ['default', 'admin'],
  );
  $perms->discover;

  my $summary = $perms->summary;
  ok(length($summary) > 0, 'summary is not empty');
  like($summary, qr/default/, 'summary mentions default namespace');
  like($summary, qr/admin/, 'summary mentions admin namespace');
  like($summary, qr/pods/, 'summary mentions pods');
};

done_testing;
