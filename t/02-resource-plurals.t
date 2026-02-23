use strict;
use warnings;
use Test::More;

# Test the resource plural mapping without connecting to a cluster.
# We access _resource_plural via a minimal MCP::K8s instance.

# We can't instantiate MCP::K8s without a cluster, but we can
# test the class method by reaching into the package.
use MCP::K8s;

# Create a bare object without triggering lazy builders
my $k8s = bless {}, 'MCP::K8s';

subtest 'common resource plurals' => sub {
  my %expected = (
    Pod                   => 'pods',
    Service               => 'services',
    Deployment            => 'deployments',
    ReplicaSet            => 'replicasets',
    StatefulSet           => 'statefulsets',
    DaemonSet             => 'daemonsets',
    Job                   => 'jobs',
    CronJob               => 'cronjobs',
    ConfigMap             => 'configmaps',
    Secret                => 'secrets',
    Namespace             => 'namespaces',
    Node                  => 'nodes',
    PersistentVolume      => 'persistentvolumes',
    PersistentVolumeClaim => 'persistentvolumeclaims',
    ServiceAccount        => 'serviceaccounts',
    Role                  => 'roles',
    RoleBinding           => 'rolebindings',
    ClusterRole           => 'clusterroles',
    ClusterRoleBinding    => 'clusterrolebindings',
    Ingress               => 'ingresses',
    NetworkPolicy         => 'networkpolicies',
    Event                 => 'events',
    Endpoints             => 'endpoints',
    LimitRange            => 'limitranges',
    ResourceQuota         => 'resourcequotas',
    HorizontalPodAutoscaler => 'horizontalpodautoscalers',
  );

  for my $kind (sort keys %expected) {
    is($k8s->_resource_plural($kind), $expected{$kind},
      "$kind => $expected{$kind}");
  }
};

subtest 'fallback pluralization' => sub {
  # Unknown resources use the lowercase + 's' heuristic
  is($k8s->_resource_plural('Widget'), 'widgets', 'Widget => widgets');
  is($k8s->_resource_plural('CustomThing'), 'customthings', 'CustomThing => customthings');

  # Handles trailing 'y' -> 'ies'
  is($k8s->_resource_plural('Policy'), 'policies', 'Policy => policies (y -> ies)');

  # Already ends in 's' - no double 's'
  is($k8s->_resource_plural('Status'), 'status', 'Status => status (no double s)');
};

subtest 'known plurals are stable' => sub {
  # Verify we get the same result on repeated calls
  is($k8s->_resource_plural('Pod'), 'pods', 'Pod consistent (1)');
  is($k8s->_resource_plural('Pod'), 'pods', 'Pod consistent (2)');
};

done_testing;
