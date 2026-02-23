package MCP::K8s;
# ABSTRACT: MCP Server for Kubernetes with RBAC-aware dynamic tools

use Moo;
use MCP::Server;
use MCP::K8s::Permissions;
use Kubernetes::REST::Kubeconfig;
use JSON::MaybeXS;
use Carp qw( croak );
use namespace::clean;

our $VERSION = '0.001';

=head1 SYNOPSIS

  # Start the MCP server on stdio (for Claude Desktop, Claude Code, etc.)
  use MCP::K8s;
  MCP::K8s->run_stdio;

  # Or use the included script:
  $ mcp-k8s

  # Configure via environment variables:
  $ export MCP_K8S_CONTEXT="my-cluster"
  $ export MCP_K8S_NAMESPACES="default,production"
  $ mcp-k8s

  # Programmatic usage with custom API:
  use MCP::K8s;
  my $k8s = MCP::K8s->new(
    api        => $my_kubernetes_rest_instance,
    namespaces => ['default', 'staging'],
  );
  $k8s->server->to_stdio;

=head1 DESCRIPTION

MCP::K8s provides an MCP (Model Context Protocol) server that gives AI
assistants like Claude access to Kubernetes clusters.

The key innovation: B<the server dynamically discovers what the connected
service account can do via RBAC> and only exposes those capabilities as
MCP tools. A read-only service account gets read-only tools; a cluster-admin
gets everything. Tool descriptions include the specific resources and
namespaces available, so the LLM always knows exactly what it can do.

=head2 How it works

=over 4

=item 1. B<Connect> — Reads kubeconfig (or uses provided API client) to connect to a Kubernetes cluster

=item 2. B<Discover> — Submits C<SelfSubjectRulesReview> requests to discover RBAC permissions per namespace

=item 3. B<Register> — Creates MCP tools with dynamic descriptions reflecting actual permissions

=item 4. B<Serve> — Runs the MCP protocol over stdio, checking permissions on every tool call

=back

=head2 Why generic tools?

Kubernetes has 50+ built-in resource types plus unlimited Custom Resources.
Instead of creating hundreds of specific tools (C<list_pods>, C<get_deployment>,
C<delete_configmap>...), MCP::K8s uses 7 generic tools with a C<resource>
parameter — the same pattern as C<kubectl get>, C<kubectl delete>, etc.
This keeps the tool count manageable for MCP clients while supporting
every resource type including CRDs.

Built on top of L<Kubernetes::REST> (API client), L<IO::K8s> (typed objects),
and L<MCP::Server> (protocol implementation).

=cut

# Map common resource short names to their plural form for RBAC checking.
# This is necessary because RBAC rules use plural resource names (e.g. "pods")
# while the Kubernetes::REST API accepts singular Kind names (e.g. "Pod").
my %RESOURCE_PLURALS = (
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
  HorizontalPodAutoscaler => 'horizontalpodautoscalers',
  Event                 => 'events',
  Endpoints             => 'endpoints',
  LimitRange            => 'limitranges',
  ResourceQuota         => 'resourcequotas',
);

has context_name => (
  is        => 'ro',
  lazy      => 1,
  default   => sub { $ENV{MCP_K8S_CONTEXT} },
  predicate => 1,
);

=attr context_name

Optional. Kubeconfig context name to use. Read from C<$ENV{MCP_K8S_CONTEXT}>
by default. If not set, the kubeconfig's C<current-context> is used.

=cut

has namespaces => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_namespaces',
);

=attr namespaces

ArrayRef of namespace names to operate on. Configured via:

=over 4

=item * C<$ENV{MCP_K8S_NAMESPACES}> — comma-separated list (e.g. C<"default,production">)

=item * Auto-discovery — lists all namespaces from the cluster

=item * Fallback — C<['default']> if discovery fails

=back

=cut

has api => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_api',
);

=attr api

L<Kubernetes::REST> instance for cluster communication. Built automatically
from kubeconfig using L<Kubernetes::REST::Kubeconfig>. Can be provided
directly for testing or custom configurations.

=cut

has permissions => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_permissions',
);

=attr permissions

L<MCP::K8s::Permissions> instance holding the discovered RBAC permissions.
Built and populated automatically on first access via C<SelfSubjectRulesReview>.

=cut

has json => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    JSON::MaybeXS->new(utf8 => 1, pretty => 1, canonical => 1, convert_blessed => 1);
  },
);

=attr json

L<JSON::MaybeXS> encoder instance. Configured with C<utf8>, C<pretty>,
C<canonical>, and C<convert_blessed> for consistent, readable output.

=cut

has server => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_server',
);

=attr server

L<MCP::Server> instance with all MCP tools registered. Built lazily,
which triggers RBAC discovery and tool registration. See L</MCP TOOLS>
for the full list of registered tools.

=cut

sub _build_api {
  my ($self) = @_;
  my %kc_args;
  $kc_args{context_name} = $self->context_name if $self->has_context_name;
  my $kc = Kubernetes::REST::Kubeconfig->new(%kc_args);
  return $kc->api;
}

sub _build_namespaces {
  my ($self) = @_;

  # From environment variable
  if (my $env = $ENV{MCP_K8S_NAMESPACES}) {
    return [ split /,/, $env ];
  }

  # Auto-discover from cluster
  my $list = eval { $self->api->list('Namespace') };
  if ($@ || !$list) {
    return ['default'];
  }

  my @ns = map { $_->metadata->name } @{ $list->items // [] };
  return @ns ? \@ns : ['default'];
}

sub _build_permissions {
  my ($self) = @_;
  my $perms = MCP::K8s::Permissions->new(
    api        => $self->api,
    namespaces => $self->namespaces,
  );
  $perms->discover;
  return $perms;
}

sub _to_json {
  my ($self, $data) = @_;
  return $self->json->encode($data);
}

sub _resource_plural {
  my ($self, $resource) = @_;

=method _resource_plural

  my $plural = $self->_resource_plural('Pod');       # => 'pods'
  my $plural = $self->_resource_plural('Ingress');   # => 'ingresses'

Convert a Kubernetes Kind name (e.g. C<Pod>, C<Deployment>) to its plural
form used in RBAC rules (e.g. C<pods>, C<deployments>). Uses a built-in
map for common resources, with a fallback heuristic for unknown types.

=cut

  return $RESOURCE_PLURALS{$resource} if $RESOURCE_PLURALS{$resource};
  # Fallback: lowercase + simple pluralization
  my $plural = lc($resource);
  $plural .= 's' unless $plural =~ /s$/;
  $plural =~ s/ys$/ies/;
  return $plural;
}

sub _resolve_namespace {
  my ($self, $args) = @_;

=method _resolve_namespace

  my $ns = $self->_resolve_namespace($args);

Resolve the namespace for a tool call. If C<< $args->{namespace} >> is
provided, uses that. Otherwise, if only one namespace is accessible,
auto-fills it. Returns C<undef> if the namespace cannot be determined
(the tool should handle this case).

=cut

  my $ns = $args->{namespace};
  return $ns if defined $ns && length $ns;

  # Auto-fill if only one namespace accessible
  my @allowed = $self->permissions->allowed_namespaces;
  return $allowed[0] if @allowed == 1;

  return undef;
}

sub _format_resource_summary {
  my ($self, $obj) = @_;

=method _format_resource_summary

  my $summary = $self->_format_resource_summary($io_k8s_object);

Extract a concise summary hashref from an L<IO::K8s> object, suitable for
LLM consumption. Includes metadata (name, namespace, labels, creation time),
kind, status fields (phase, replicas, conditions), and key spec fields
(containers, ports, type).

The summary is intentionally compact — for full details, the C<k8s_get>
tool with C<output =E<gt> 'json'> should be used.

=cut

  my %summary;

  if ($obj->can('metadata') && $obj->metadata) {
    my $meta = $obj->metadata;
    $summary{name}      = $meta->name if $meta->can('name');
    $summary{namespace} = $meta->namespace if $meta->can('namespace') && $meta->namespace;
    $summary{labels}    = $meta->labels if $meta->can('labels') && $meta->labels;
    $summary{creationTimestamp} = $meta->creationTimestamp if $meta->can('creationTimestamp') && $meta->creationTimestamp;
  }

  if ($obj->can('kind') && $obj->kind) {
    $summary{kind} = $obj->kind;
  }

  if ($obj->can('status') && $obj->status) {
    my $status = $obj->status;
    $summary{phase} = $status->phase if $status->can('phase') && $status->phase;
    $summary{replicas} = $status->replicas if $status->can('replicas') && defined $status->replicas;
    $summary{readyReplicas} = $status->readyReplicas if $status->can('readyReplicas') && defined $status->readyReplicas;
    $summary{availableReplicas} = $status->availableReplicas if $status->can('availableReplicas') && defined $status->availableReplicas;
    $summary{conditions} = $status->conditions if $status->can('conditions') && $status->conditions;
  }

  if ($obj->can('spec') && $obj->spec) {
    my $spec = $obj->spec;
    $summary{replicas} //= $spec->replicas if $spec->can('replicas') && defined $spec->replicas;
    if ($spec->can('containers') && $spec->containers) {
      $summary{containers} = [ map { $_->name } @{ $spec->containers } ];
    }
    if ($spec->can('type') && $spec->type) {
      $summary{type} = $spec->type;
    }
    if ($spec->can('ports') && $spec->ports) {
      $summary{ports} = [ map {
        my $p = $_;
        my %port;
        $port{port}       = $p->port if $p->can('port') && defined $p->port;
        $port{targetPort} = $p->targetPort if $p->can('targetPort') && defined $p->targetPort;
        $port{protocol}   = $p->protocol if $p->can('protocol') && $p->protocol;
        \%port;
      } @{ $spec->ports } ];
    }
  }

  return \%summary;
}

sub _format_list {
  my ($self, $items) = @_;

=method _format_list

  my $summaries = $self->_format_list($list->items);

Format an arrayref of L<IO::K8s> objects into an arrayref of summary
hashrefs using L</_format_resource_summary>.

=cut

  my @summaries;
  for my $item (@{ $items // [] }) {
    push @summaries, $self->_format_resource_summary($item);
  }
  return \@summaries;
}

sub _available_resources_desc {
  my ($self, $verb) = @_;
  my @parts;
  for my $ns ($self->permissions->allowed_namespaces) {
    my @resources = $self->permissions->allowed_resources($verb, $ns);
    if (@resources) {
      my @display = grep { $_ ne '*' } @resources;
      if (grep { $_ eq '*' } @resources) {
        push @parts, "$ns: all resources";
      } elsif (@display > 10) {
        push @parts, "$ns: " . join(', ', @display[0..9]) . ", ...";
      } else {
        push @parts, "$ns: " . join(', ', @display);
      }
    }
  }
  return join('; ', @parts) || 'none discovered';
}

=head1 MCP TOOLS

All tools are registered on the L</server> during construction. Each tool
checks RBAC permissions before executing and returns clear error messages
on denial. Tool descriptions dynamically include which resources and
namespaces are available.

=head2 k8s_permissions

Show what the current Kubernetes service account is allowed to do. Returns
a Markdown-formatted RBAC summary. B<The LLM should call this first> to
understand its capabilities.

No parameters required.

=head2 k8s_list

List Kubernetes resources with optional filtering.

B<Parameters:>

=over 4

=item C<resource> (string, B<required>) — Resource type: C<Pod>, C<Deployment>, C<Service>, C<ConfigMap>, etc.

=item C<namespace> (string) — Target namespace. Auto-detected if only one is accessible.

=item C<label_selector> (string) — Label filter, e.g. C<app=web,env=prod>

=item C<field_selector> (string) — Field filter, e.g. C<status.phase=Running>

=back

Returns JSON with C<count> and C<items> (array of resource summaries).

=head2 k8s_get

Get a single Kubernetes resource by name.

B<Parameters:>

=over 4

=item C<resource> (string, B<required>) — Resource type

=item C<name> (string, B<required>) — Resource name

=item C<namespace> (string) — Target namespace

=item C<output> (string) — Format: C<summary> (default), C<json>, or C<yaml>

=back

=head2 k8s_create

Create a Kubernetes resource from a manifest. The C<apiVersion> and C<kind>
fields are auto-populated from the resource type via L<IO::K8s>.

B<Parameters:>

=over 4

=item C<resource> (string, B<required>) — Resource type

=item C<manifest> (object, B<required>) — Resource manifest (metadata, spec, etc.)

=item C<namespace> (string) — Target namespace (also auto-populated in metadata)

=back

Returns JSON confirmation with the created resource name.

=head2 k8s_patch

Partially update a Kubernetes resource.

B<Parameters:>

=over 4

=item C<resource> (string, B<required>) — Resource type

=item C<name> (string, B<required>) — Resource name

=item C<patch> (object, B<required>) — Fields to change

=item C<namespace> (string) — Target namespace

=item C<patch_type> (string) — Strategy: C<strategic> (default), C<merge>, or C<json>

=back

See L<Kubernetes::REST/patch> for details on patch strategies.

=head2 k8s_delete

Delete a Kubernetes resource by name.

B<Parameters:>

=over 4

=item C<resource> (string, B<required>) — Resource type

=item C<name> (string, B<required>) — Resource name

=item C<namespace> (string) — Target namespace

=back

=head2 k8s_logs

Get container logs from a pod. Essential for debugging. Uses the raw
C</api/v1/namespaces/{ns}/pods/{name}/log> endpoint.

B<Parameters:>

=over 4

=item C<name> (string, B<required>) — Pod name

=item C<namespace> (string) — Target namespace (B<required> for logs)

=item C<container> (string) — Container name (required for multi-container pods)

=item C<tail_lines> (integer) — Number of lines from end (default: 100)

=item C<previous> (boolean) — Get logs from previous container instance

=back

=cut

sub _build_server {
  my ($self) = @_;

  my $server = MCP::Server->new(
    name    => 'MCP-K8s',
    version => $VERSION,
  );

  # ---- Tool 1: k8s_permissions ----
  $server->tool(
    name        => 'k8s_permissions',
    description => 'Show what this Kubernetes service account is allowed to do (RBAC permissions). Call this first to understand available capabilities.',
    input_schema => {
      type       => 'object',
      properties => {},
    },
    code => sub {
      my ($tool, $args) = @_;
      return $self->permissions->summary;
    },
  );

  # ---- Tool 2: k8s_list ----
  my $list_desc = 'List Kubernetes resources. Available: ' . $self->_available_resources_desc('list');
  $server->tool(
    name        => 'k8s_list',
    description => $list_desc,
    input_schema => {
      type       => 'object',
      properties => {
        resource => {
          type        => 'string',
          description => 'Resource type (e.g. Pod, Deployment, Service, ConfigMap)',
        },
        namespace => {
          type        => 'string',
          description => 'Namespace (auto-detected if only one available)',
        },
        label_selector => {
          type        => 'string',
          description => 'Label selector filter (e.g. app=web)',
        },
        field_selector => {
          type        => 'string',
          description => 'Field selector filter (e.g. status.phase=Running)',
        },
      },
      required => ['resource'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $resource = $args->{resource};
      my $ns = $self->_resolve_namespace($args);
      my $plural = $self->_resource_plural($resource);

      unless ($self->permissions->can_do('list', $plural, $ns // '')) {
        return "Permission denied: cannot list $resource" . ($ns ? " in namespace $ns" : "");
      }

      my %api_args;
      $api_args{namespace}     = $ns if defined $ns;
      $api_args{labelSelector} = $args->{label_selector} if $args->{label_selector};
      $api_args{fieldSelector} = $args->{field_selector} if $args->{field_selector};

      my $list = eval { $self->api->list($resource, %api_args) };
      return "Failed to list $resource: $@" if $@;

      my $items = $list->items // [];
      return "No $resource resources found" unless @$items;

      my $summaries = $self->_format_list($items);
      return $self->_to_json({
        count => scalar @$items,
        items => $summaries,
      });
    },
  );

  # ---- Tool 3: k8s_get ----
  my $get_desc = 'Get a single Kubernetes resource. Available: ' . $self->_available_resources_desc('get');
  $server->tool(
    name        => 'k8s_get',
    description => $get_desc,
    input_schema => {
      type       => 'object',
      properties => {
        resource => {
          type        => 'string',
          description => 'Resource type (e.g. Pod, Deployment, Service)',
        },
        name => {
          type        => 'string',
          description => 'Resource name',
        },
        namespace => {
          type        => 'string',
          description => 'Namespace (auto-detected if only one available)',
        },
        output => {
          type        => 'string',
          description => 'Output format: summary (default), json, yaml',
          enum        => ['summary', 'json', 'yaml'],
        },
      },
      required => ['resource', 'name'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $resource = $args->{resource};
      my $name     = $args->{name};
      my $ns       = $self->_resolve_namespace($args);
      my $output   = $args->{output} // 'summary';
      my $plural   = $self->_resource_plural($resource);

      unless ($self->permissions->can_do('get', $plural, $ns // '')) {
        return "Permission denied: cannot get $resource" . ($ns ? " in namespace $ns" : "");
      }

      my %api_args = (name => $name);
      $api_args{namespace} = $ns if defined $ns;

      my $obj = eval { $self->api->get($resource, %api_args) };
      return "Failed to get $resource/$name: $@" if $@;

      if ($output eq 'json') {
        return $self->_to_json($obj->TO_JSON);
      } elsif ($output eq 'yaml') {
        eval { require YAML::XS };
        if ($@) {
          return $self->_to_json($obj->TO_JSON);
        }
        return YAML::XS::Dump($obj->TO_JSON);
      } else {
        return $self->_to_json($self->_format_resource_summary($obj));
      }
    },
  );

  # ---- Tool 4: k8s_create ----
  my $create_desc = 'Create a Kubernetes resource. Available: ' . $self->_available_resources_desc('create');
  $server->tool(
    name        => 'k8s_create',
    description => $create_desc,
    input_schema => {
      type       => 'object',
      properties => {
        resource => {
          type        => 'string',
          description => 'Resource type (e.g. Pod, Deployment, ConfigMap)',
        },
        namespace => {
          type        => 'string',
          description => 'Namespace for the resource',
        },
        manifest => {
          type        => 'object',
          description => 'Resource manifest (apiVersion/kind auto-populated from resource type)',
        },
      },
      required => ['resource', 'manifest'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $resource = $args->{resource};
      my $ns       = $self->_resolve_namespace($args);
      my $manifest = $args->{manifest};
      my $plural   = $self->_resource_plural($resource);

      unless ($self->permissions->can_do('create', $plural, $ns // '')) {
        return "Permission denied: cannot create $resource" . ($ns ? " in namespace $ns" : "");
      }

      # Auto-populate namespace in metadata
      if (defined $ns) {
        $manifest->{metadata} //= {};
        $manifest->{metadata}{namespace} //= $ns;
      }

      my $obj = eval { $self->api->new_object($resource, $manifest) };
      return "Failed to build $resource object: $@" if $@;

      my $created = eval { $self->api->create($obj) };
      return "Failed to create $resource: $@" if $@;

      my $created_name = eval { $created->metadata->name } // 'unknown';
      return $self->_to_json({
        status  => 'created',
        kind    => $resource,
        name    => $created_name,
        ($ns ? (namespace => $ns) : ()),
      });
    },
  );

  # ---- Tool 5: k8s_patch ----
  my $patch_desc = 'Patch (partial update) a Kubernetes resource. Available: ' . $self->_available_resources_desc('patch');
  $server->tool(
    name        => 'k8s_patch',
    description => $patch_desc,
    input_schema => {
      type       => 'object',
      properties => {
        resource => {
          type        => 'string',
          description => 'Resource type (e.g. Deployment, Service)',
        },
        name => {
          type        => 'string',
          description => 'Resource name',
        },
        namespace => {
          type        => 'string',
          description => 'Namespace',
        },
        patch => {
          type        => 'object',
          description => 'Patch body (fields to change)',
        },
        patch_type => {
          type        => 'string',
          description => 'Patch strategy: strategic (default), merge, json',
          enum        => ['strategic', 'merge', 'json'],
        },
      },
      required => ['resource', 'name', 'patch'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $resource   = $args->{resource};
      my $name       = $args->{name};
      my $ns         = $self->_resolve_namespace($args);
      my $patch      = $args->{patch};
      my $patch_type = $args->{patch_type} // 'strategic';
      my $plural     = $self->_resource_plural($resource);

      unless ($self->permissions->can_do('patch', $plural, $ns // '')) {
        return "Permission denied: cannot patch $resource" . ($ns ? " in namespace $ns" : "");
      }

      my %api_args = (
        patch => $patch,
        type  => $patch_type,
      );
      $api_args{namespace} = $ns if defined $ns;

      my $patched = eval { $self->api->patch($resource, $name, %api_args) };
      return "Failed to patch $resource/$name: $@" if $@;

      return $self->_to_json({
        status => 'patched',
        kind   => $resource,
        name   => $name,
        ($ns ? (namespace => $ns) : ()),
      });
    },
  );

  # ---- Tool 6: k8s_delete ----
  my $delete_desc = 'Delete a Kubernetes resource. Available: ' . $self->_available_resources_desc('delete');
  $server->tool(
    name        => 'k8s_delete',
    description => $delete_desc,
    input_schema => {
      type       => 'object',
      properties => {
        resource => {
          type        => 'string',
          description => 'Resource type (e.g. Pod, Deployment)',
        },
        name => {
          type        => 'string',
          description => 'Resource name',
        },
        namespace => {
          type        => 'string',
          description => 'Namespace',
        },
      },
      required => ['resource', 'name'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $resource = $args->{resource};
      my $name     = $args->{name};
      my $ns       = $self->_resolve_namespace($args);
      my $plural   = $self->_resource_plural($resource);

      unless ($self->permissions->can_do('delete', $plural, $ns // '')) {
        return "Permission denied: cannot delete $resource" . ($ns ? " in namespace $ns" : "");
      }

      my %api_args = (name => $name);
      $api_args{namespace} = $ns if defined $ns;

      eval { $self->api->delete($resource, %api_args) };
      return "Failed to delete $resource/$name: $@" if $@;

      return $self->_to_json({
        status => 'deleted',
        kind   => $resource,
        name   => $name,
        ($ns ? (namespace => $ns) : ()),
      });
    },
  );

  # ---- Tool 7: k8s_logs ----
  my @log_ns = grep {
    $self->permissions->can_read_logs($_)
  } $self->permissions->allowed_namespaces;
  my $logs_desc = 'Get pod logs. Available in namespaces: ' . (join(', ', @log_ns) || 'none');
  $server->tool(
    name        => 'k8s_logs',
    description => $logs_desc,
    input_schema => {
      type       => 'object',
      properties => {
        name => {
          type        => 'string',
          description => 'Pod name',
        },
        namespace => {
          type        => 'string',
          description => 'Namespace (auto-detected if only one available)',
        },
        container => {
          type        => 'string',
          description => 'Container name (required for multi-container pods)',
        },
        tail_lines => {
          type        => 'integer',
          description => 'Number of lines from end (default: 100)',
        },
        previous => {
          type        => 'boolean',
          description => 'Get logs from previous container instance',
        },
      },
      required => ['name'],
    },
    code => sub {
      my ($tool, $args) = @_;

      my $name       = $args->{name};
      my $ns         = $self->_resolve_namespace($args);
      my $container  = $args->{container};
      my $tail_lines = $args->{tail_lines} // 100;
      my $previous   = $args->{previous} // 0;

      unless ($ns) {
        return "Namespace required for pod logs";
      }

      unless ($self->permissions->can_read_logs($ns)) {
        return "Permission denied: cannot read pod logs in namespace $ns";
      }

      # Build the log URL path directly
      my $path = "/api/v1/namespaces/$ns/pods/$name/log";
      my %params;
      $params{tailLines} = $tail_lines if $tail_lines;
      $params{container} = $container if $container;
      $params{previous}  = 'true' if $previous;

      my $response = eval { $self->api->_request('GET', $path, undef, parameters => \%params) };
      return "Failed to get logs for pod/$name: $@" if $@;

      if ($response->status >= 400) {
        return "Error getting logs: " . $response->status . " " . ($response->content // '');
      }

      my $content = $response->content // '';
      return $content || "(no log output)";
    },
  );

  return $server;
}

sub run_stdio {
  my ($self) = @_;

=method run_stdio

  # As class method:
  MCP::K8s->run_stdio;

  # As instance method:
  my $k8s = MCP::K8s->new(%opts);
  $k8s->run_stdio;

Start the MCP server on stdio. If called as a class method, creates a
new instance first. This is the main entry point used by the C<mcp-k8s>
script.

=cut

  $self = $self->new unless ref $self;
  $self->server->to_stdio;
}

1;

=head1 ENVIRONMENT

=over 4

=item C<KUBECONFIG>

Path to kubeconfig file. Default: C<~/.kube/config>.
Standard Kubernetes environment variable, also used by C<kubectl>.

=item C<MCP_K8S_CONTEXT>

Kubeconfig context to use. Default: the kubeconfig's C<current-context>.

=item C<MCP_K8S_NAMESPACES>

Comma-separated list of namespaces to operate on.
Default: auto-discovered from the cluster (lists all namespaces the
service account can see). Falls back to C<default> if discovery fails.

=back

=head1 CLAUDE DESKTOP INTEGRATION

Add this to your Claude Desktop MCP configuration
(C<~/.config/claude/claude_desktop_config.json>):

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

=head1 CLAUDE CODE INTEGRATION

Add to your project's C<.mcp.json> or global MCP settings:

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

=head1 SECURITY CONSIDERATIONS

=over 4

=item * The server inherits the permissions of whatever kubeconfig context
it connects with. Use a dedicated service account with minimal RBAC
permissions for AI assistant access.

=item * All tool calls check RBAC permissions B<before> executing. Even if
the service account has broad permissions, the permission check provides
a clear audit trail.

=item * Secrets are supported as a resource type. If your service account
can read secrets, the LLM will be able to read them too. Consider excluding
C<secrets> from RBAC roles used for AI access.

=back

=seealso

L<MCP::K8s::Permissions> — RBAC discovery engine

L<MCP::Kubernetes> — Alias for this module

L<Kubernetes::REST> — The underlying Kubernetes API client

L<IO::K8s> — Typed Kubernetes resource objects

L<MCP::Server> — MCP protocol implementation

L<Kubernetes::REST::Kubeconfig> — Kubeconfig parsing

L<https://modelcontextprotocol.io/> — Model Context Protocol specification

L<https://kubernetes.io/docs/reference/access-authn-authz/rbac/> — Kubernetes RBAC

=cut
