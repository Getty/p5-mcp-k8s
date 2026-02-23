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

1. **Connect** — Reads your kubeconfig to connect to a Kubernetes cluster
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

### Why 7 generic tools instead of hundreds?

Kubernetes has 50+ built-in resource types plus unlimited CRDs. Instead of creating specific tools (`list_pods`, `get_deployment`, `delete_configmap`...), MCP::K8s uses generic tools with a `resource` parameter — the same pattern as `kubectl get <resource>`, `kubectl delete <resource>`. This keeps the tool count manageable for MCP clients while supporting every resource type.

### Dynamic Tool Descriptions

Tool descriptions include the specific resources and namespaces available based on RBAC. For example:

> "List Kubernetes resources. Available: default: pods, deployments, services, configmaps; production: pods, services"

This tells the LLM exactly what it can do without needing to call `k8s_permissions` first (though it should, for the full picture).

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KUBECONFIG` | Path to kubeconfig file | `~/.kube/config` |
| `MCP_K8S_CONTEXT` | Kubeconfig context to use | current-context |
| `MCP_K8S_NAMESPACES` | Comma-separated namespaces | auto-discover |

## Security

- The server inherits permissions from the kubeconfig context. Use a dedicated service account with minimal RBAC for AI access.
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
