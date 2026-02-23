use strict;
use warnings;
use Test::More;

use MCP::Kubernetes;
use MCP::K8s;

subtest 'MCP::Kubernetes is a subclass of MCP::K8s' => sub {
  ok(MCP::Kubernetes->isa('MCP::K8s'), 'MCP::Kubernetes isa MCP::K8s');
};

subtest 'has all MCP::K8s methods' => sub {
  for my $method (qw(run_stdio new server api permissions namespaces json context_name)) {
    ok(MCP::Kubernetes->can($method), "MCP::Kubernetes can $method");
  }
};

subtest 'version matches MCP::K8s' => sub {
  is($MCP::Kubernetes::VERSION, $MCP::K8s::VERSION,
    'MCP::Kubernetes version matches MCP::K8s');
};

done_testing;
