# MCP::K8s - MCP Server for Kubernetes

**RBAC-aware Kubernetes tools for AI assistants**

[![CPAN Version](https://img.shields.io/cpan/v/MCP-K8s.svg)](https://metacpan.org/release/MCP-K8s)
[![License](https://img.shields.io/cpan/l/MCP-K8s.svg)](https://metacpan.org/release/MCP-K8s)

MCP::K8s provides an [MCP](https://modelcontextprotocol.io/) (Model Context Protocol) server that gives AI assistants like Claude access to Kubernetes clusters.

The key innovation: **the server dynamically discovers what the connected service account can do via RBAC** and only exposes those capabilities as MCP tools. A read-only service account gets read-only tools; a cluster-admin gets everything.

## Quick Start

```bash
# Install
cpanm MCP::K8s

# Run (uses current kubeconfig context)
mcp-k8s

# Or with direct token authentication
MCP_K8S_TOKEN=$(kubectl create token my-sa) MCP_K8S_SERVER=https://my-cluster:6443 mcp-k8s
```

## Claude Desktop

Add to `~/.config/claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "kubernetes": {
      "command": "mcp-k8s",
      "env": {
        "MCP_K8S_CONTEXT": "my-cluster",
        "MCP_K8S_NAMESPACES": "default,production"
      }
    }
  }
}
```

## Claude Code

Add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "kubernetes": {
      "command": "mcp-k8s",
      "env": {
        "MCP_K8S_CONTEXT": "dev-cluster"
      }
    }
  }
}
```

## How It Works

1. **Connect** — Authenticates via direct token, in-cluster service account, or kubeconfig
2. **Discover** — Submits `SelfSubjectRulesReview` requests to discover RBAC permissions per namespace
3. **Register** — Creates MCP tools with dynamic descriptions reflecting actual permissions
4. **Serve** — Runs the MCP protocol over stdio, checking permissions on every tool call

## MCP Tools

| Tool | Description |
|------|-------------|
| `k8s_permissions` | Show RBAC permissions — **call this first** |
| `k8s_list` | List resources (Pods, Deployments, Services, ...) |
| `k8s_get` | Get a single resource (summary, JSON, or YAML) |
| `k8s_create` | Create a resource from a manifest |
| `k8s_patch` | Partially update a resource (strategic/merge/JSON patch) |
| `k8s_delete` | Delete a resource |
| `k8s_logs` | Get pod container logs |
| `k8s_events` | Get events for debugging (filter by object, field selector) |
| `k8s_rollout_restart` | Trigger rolling restart of Deployment/StatefulSet/DaemonSet |
| `k8s_apply` | Create or update a resource (like `kubectl apply`) |

### Why 10 generic tools instead of hundreds?

Kubernetes has 50+ built-in resource types plus unlimited CRDs. Instead of creating specific tools (`list_pods`, `get_deployment`, `delete_configmap`...), MCP::K8s uses generic tools with a `resource` parameter — the same pattern as `kubectl get <resource>`, `kubectl delete <resource>`. This keeps the tool count manageable for MCP clients while supporting every resource type including CRDs.

### Dynamic Tool Descriptions

Tool descriptions include the specific resources and namespaces available based on RBAC. For example:

> "List Kubernetes resources. Available: default: pods, deployments, services, configmaps; production: pods, services"

This tells the LLM exactly what it can do without needing to call `k8s_permissions` first (though it should, for the full picture).

### CRD Support

MCP::K8s supports Custom Resource Definitions (CRDs) out of the box. Resource plurals are resolved dynamically via API server discovery, so CRDs like Cilium's `CiliumNetworkPolicy` work without any configuration.

## Authentication

MCP::K8s supports three authentication methods, tried in order:

| Method | Configuration | Use Case |
|--------|--------------|----------|
| **Direct token** | `MCP_K8S_TOKEN` + `MCP_K8S_SERVER` | CI/CD, scripts, explicit token |
| **In-cluster** | Auto-detected from SA mount | Running as a Kubernetes pod |
| **Kubeconfig** | `KUBECONFIG` + `MCP_K8S_CONTEXT` | Local development (default) |

In-cluster auth reads the service account token from `/var/run/secrets/kubernetes.io/serviceaccount/token` and uses the in-cluster CA certificate automatically.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KUBECONFIG` | Path to kubeconfig file | `~/.kube/config` |
| `MCP_K8S_CONTEXT` | Kubeconfig context to use | current-context |
| `MCP_K8S_TOKEN` | Bearer token (bypasses kubeconfig) | — |
| `MCP_K8S_SERVER` | API server URL | in-cluster default |
| `MCP_K8S_NAMESPACES` | Comma-separated namespaces | auto-discover |

## RBAC Setup

Use a dedicated ServiceAccount with minimal permissions. Example manifests are included in [`examples/`](examples/):

- **[`readonly-serviceaccount.yaml`](examples/readonly-serviceaccount.yaml)** — Read-only access (recommended starting point)
- **[`deployer-serviceaccount.yaml`](examples/deployer-serviceaccount.yaml)** — Read + deploy/restart capabilities
- **[`full-ops-serviceaccount.yaml`](examples/full-ops-serviceaccount.yaml)** — Full access except secrets

```bash
# Apply the readonly example
kubectl apply -f examples/readonly-serviceaccount.yaml

# Get a token
MCP_K8S_TOKEN=$(kubectl create token mcp-k8s-readonly -n mcp-k8s)
MCP_K8S_SERVER=https://$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
mcp-k8s
```

RBAC is the single source of truth — if the service account shouldn't have access, don't grant it. MCP::K8s does **not** implement application-layer permission filtering.

## In-Cluster Deployment

When running MCP::K8s as a pod inside the cluster, authentication is automatic:

1. Mount a ServiceAccount (e.g. from the examples above)
2. Set `MCP_K8S_NAMESPACES` if needed (otherwise auto-discovers from the mounted SA namespace)
3. The in-cluster token and CA cert are read automatically

## Security

- The server inherits permissions from its authentication method. Use a dedicated service account with minimal RBAC for AI access.
- All tool calls verify RBAC permissions **before** executing API calls.
- If the service account can read Secrets, the LLM can too. Consider excluding `secrets` from AI service account roles.

## Langertha Raider Integration

Build an autonomous AI agent that manages your Kubernetes cluster using [Langertha::Raider](https://metacpan.org/pod/Langertha::Raider):

```perl
use IO::Async::Loop;
use Future::AsyncAwait;
use Net::Async::MCP;
use Langertha::Engine::Anthropic;
use Langertha::Raider;
use MCP::K8s;

my $k8s = MCP::K8s->new(namespaces => ['default', 'production']);

my $loop = IO::Async::Loop->new;
my $mcp = Net::Async::MCP->new(server => $k8s->server);
$loop->add($mcp);

async sub main {
  await $mcp->initialize;

  my $engine = Langertha::Engine::Anthropic->new(
    api_key     => $ENV{ANTHROPIC_API_KEY},
    model       => 'claude-sonnet-4-6',
    mcp_servers => [$mcp],
  );

  my $raider = Langertha::Raider->new(
    engine  => $engine,
    mission => 'You are a Kubernetes operations assistant. '
             . 'Always check permissions first, then help the user '
             . 'investigate and manage their cluster.',
  );

  my $r1 = await $raider->raid_f('What can I do on this cluster?');
  say $r1;

  # Follow-up raid — has context from the first
  my $r2 = await $raider->raid_f('List all pods and check for any issues.');
  say $r2;
}

main()->get;
```

The Raider maintains conversation history across raids, so the LLM can reference earlier context (e.g. the RBAC permissions it discovered) in follow-up interactions.

### Live Demo

A ready-to-run demo script is included in `examples/raider-configmap-demo.pl`. It has an AI create, read, update, and delete a ConfigMap — completely harmless:

```bash
LANGERTHA_ANTHROPIC_API_KEY=sk-ant-... perl -Ilib examples/raider-configmap-demo.pl
```

The AI decides which MCP tools to call, reports each step, and cleans up after itself. See the script's POD for details and requirements.

## Dependencies

- [MCP](https://metacpan.org/pod/MCP) — Model Context Protocol server implementation
- [Kubernetes::REST](https://metacpan.org/pod/Kubernetes::REST) — Kubernetes API client
- [IO::K8s](https://metacpan.org/pod/IO::K8s) — Typed Kubernetes resource objects
- [Moo](https://metacpan.org/pod/Moo) — Minimalist OOP

## Also Available As

`MCP::Kubernetes` — Alias module for discoverability on CPAN.

## Author

Torsten Raudssus <torsten@raudssus.de>

## License

This is free software, licensed under the same terms as Perl itself (Artistic License 2.0 / GPL).
