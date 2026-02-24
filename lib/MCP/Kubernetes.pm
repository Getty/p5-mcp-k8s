package MCP::Kubernetes;
# ABSTRACT: MCP Server for Kubernetes (alias for MCP::K8s)
our $VERSION = '0.002';
use Moo;

extends 'MCP::K8s';

1;

=head1 SYNOPSIS

  use MCP::Kubernetes;
  MCP::Kubernetes->run_stdio;

  # Exactly equivalent to:
  use MCP::K8s;
  MCP::K8s->run_stdio;

  # Full OOP usage works identically:
  my $k8s = MCP::Kubernetes->new(
    namespaces => ['default', 'production'],
  );
  $k8s->server->to_stdio;

=head1 DESCRIPTION

MCP::Kubernetes is L<MCP::K8s>. It's a subclass with no additions — a
longer, more discoverable name on CPAN for the same module.

Every attribute, method, and tool from L<MCP::K8s> works exactly the same:

  MCP::Kubernetes->new(...)      # same as MCP::K8s->new(...)
  MCP::Kubernetes->run_stdio     # same as MCP::K8s->run_stdio
  $obj->isa('MCP::K8s')         # true
  $obj->server                   # MCP::Server with all 10 tools

If you're looking for the Kubernetes MCP Server for AI assistants, see
L<MCP::K8s> for the full documentation.

=seealso

L<MCP::K8s> — Full documentation lives here

L<Kubernetes::REST> — Kubernetes API client

L<IO::K8s> — Kubernetes resource objects

=cut
