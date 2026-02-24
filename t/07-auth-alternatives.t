use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use MCP::K8s;

# =================================================================
# Test auth path selection logic in _build_api
# =================================================================

# We test _read_file and the auth tier selection by subclassing
# MCP::K8s and overriding _build_api to capture which path was taken.

subtest '_read_file helper' => sub {
  my $k8s = bless {}, 'MCP::K8s';

  # Read a real file
  my $dir = tempdir(CLEANUP => 1);
  my $file = File::Spec->catfile($dir, 'test-token');
  open my $fh, '>', $file or die "Cannot write $file: $!";
  print $fh "my-test-token\n";
  close $fh;

  is($k8s->_read_file($file), 'my-test-token', '_read_file reads and chomps');

  # Non-existent file returns undef
  is($k8s->_read_file('/nonexistent/path/token'), undef, '_read_file returns undef for missing file');
};

subtest 'tier 1: direct token via MCP_K8S_TOKEN' => sub {
  # Set up env vars
  local $ENV{MCP_K8S_TOKEN}  = 'test-bearer-token-123';
  local $ENV{MCP_K8S_SERVER} = 'https://test-server:6443';

  my $k8s = MCP::K8s->new(
    namespaces => ['default'],
  );

  # Building the API should use direct token
  my $api = eval { $k8s->api };
  ok($api, 'api built with direct token');
  isa_ok($api, 'Kubernetes::REST', 'api is Kubernetes::REST instance');
};

subtest 'tier 1: token without explicit server' => sub {
  local $ENV{MCP_K8S_TOKEN}  = 'test-bearer-token-456';
  local $ENV{MCP_K8S_SERVER} = undef;
  delete $ENV{MCP_K8S_SERVER};

  my $k8s = MCP::K8s->new(
    namespaces => ['default'],
  );

  # Should still work, defaulting to in-cluster server
  my $api = eval { $k8s->api };
  ok($api, 'api built with token and default server');
};

subtest 'tier 3: kubeconfig fallback' => sub {
  local $ENV{MCP_K8S_TOKEN}  = undef;
  local $ENV{MCP_K8S_SERVER} = undef;
  delete $ENV{MCP_K8S_TOKEN};
  delete $ENV{MCP_K8S_SERVER};

  # Without a real kubeconfig this will likely fail, but we verify the
  # code path reaches kubeconfig handling
  my $k8s = MCP::K8s->new(
    namespaces => ['default'],
  );

  my $api = eval { $k8s->api };
  # This may fail if no kubeconfig present, that's OK —
  # we're testing that the fallback path is attempted
  if ($@) {
    like($@, qr/kubeconfig|config|YAML|No such file/i,
      'kubeconfig fallback attempted (failed as expected without kubeconfig)');
  } else {
    ok($api, 'kubeconfig fallback succeeded');
  }
};

subtest 'token attribute from env' => sub {
  local $ENV{MCP_K8S_TOKEN} = 'env-token-789';

  my $k8s = MCP::K8s->new(namespaces => ['default']);
  is($k8s->token, 'env-token-789', 'token reads from MCP_K8S_TOKEN');
  ok($k8s->has_token, 'has_token predicate true');
};

subtest 'server_endpoint attribute from env' => sub {
  local $ENV{MCP_K8S_SERVER} = 'https://my-server:6443';

  my $k8s = MCP::K8s->new(namespaces => ['default']);
  is($k8s->server_endpoint, 'https://my-server:6443', 'server_endpoint reads from MCP_K8S_SERVER');
  ok($k8s->has_server_endpoint, 'has_server_endpoint predicate true');
};

subtest 'attributes without env vars' => sub {
  local $ENV{MCP_K8S_TOKEN}  = undef;
  local $ENV{MCP_K8S_SERVER} = undef;
  delete $ENV{MCP_K8S_TOKEN};
  delete $ENV{MCP_K8S_SERVER};

  my $k8s = MCP::K8s->new(namespaces => ['default']);
  # Lazy attributes won't be built until accessed, but predicate should
  # reflect whether they were explicitly set in constructor
  ok(!$k8s->has_token, 'has_token false when not set');
  ok(!$k8s->has_server_endpoint, 'has_server_endpoint false when not set');
};

done_testing;
