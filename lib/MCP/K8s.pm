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

# Map common resource short names to their plural form for RBAC checking
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

has namespaces => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_namespaces',
);

has api => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_api',
);

has permissions => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_permissions',
);

has json => (
  is      => 'ro',
  lazy    => 1,
  default => sub {
    JSON::MaybeXS->new(utf8 => 1, pretty => 1, canonical => 1, convert_blessed => 1);
  },
);

has server => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_server',
);

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
  return $RESOURCE_PLURALS{$resource} if $RESOURCE_PLURALS{$resource};
  # Fallback: lowercase + simple pluralization
  my $plural = lc($resource);
  $plural .= 's' unless $plural =~ /s$/;
  $plural =~ s/ys$/ies/;
  return $plural;
}

sub _resolve_namespace {
  my ($self, $args) = @_;
  my $ns = $args->{namespace};
  return $ns if defined $ns && length $ns;

  # Auto-fill if only one namespace accessible
  my @allowed = $self->permissions->allowed_namespaces;
  return $allowed[0] if @allowed == 1;

  return undef;
}

sub _format_resource_summary {
  my ($self, $obj) = @_;
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

      # Check permission
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
        # YAML output via JSON round-trip
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

      # Use raw _request on the api object
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
  $self = $self->new unless ref $self;
  $self->server->to_stdio;
}

1;

__END__

=head1 SYNOPSIS

  # As stdio MCP server (for Claude Desktop, Claude Code, etc.)
  use MCP::K8s;
  MCP::K8s->run_stdio;

  # Or with the included script:
  # mcp-k8s

  # Environment variables:
  export MCP_K8S_CONTEXT="my-cluster"
  export MCP_K8S_NAMESPACES="default,production"

=head1 DESCRIPTION

MCP::K8s provides an MCP (Model Context Protocol) server that gives AI
assistants like Claude access to Kubernetes clusters.

The key innovation: the server dynamically discovers what the connected
service account can do via RBAC (using SelfSubjectRulesReview) and only
exposes those capabilities as MCP tools. A read-only service account gets
read-only tools; a cluster-admin gets everything.

Built on top of L<Kubernetes::REST> (API client) and L<IO::K8s> (typed
objects).

=head1 MCP TOOLS

=head2 k8s_permissions

Show RBAC permissions for the current service account. Call this first to
understand what operations are available.

=head2 k8s_list

List Kubernetes resources with optional label and field selectors.

B<Parameters:> C<resource> (required), C<namespace>, C<label_selector>, C<field_selector>

=head2 k8s_get

Get a single Kubernetes resource by name with summary, JSON, or YAML output.

B<Parameters:> C<resource> (required), C<name> (required), C<namespace>, C<output> (summary|json|yaml)

=head2 k8s_create

Create a Kubernetes resource from a manifest. apiVersion and kind are
auto-populated from the resource type.

B<Parameters:> C<resource> (required), C<manifest> (required), C<namespace>

=head2 k8s_patch

Partially update a Kubernetes resource using strategic merge, JSON merge,
or JSON patch.

B<Parameters:> C<resource> (required), C<name> (required), C<patch> (required), C<namespace>, C<patch_type> (strategic|merge|json)

=head2 k8s_delete

Delete a Kubernetes resource by name.

B<Parameters:> C<resource> (required), C<name> (required), C<namespace>

=head2 k8s_logs

Get pod logs. Essential for debugging.

B<Parameters:> C<name> (required), C<namespace>, C<container>, C<tail_lines>, C<previous>

=head1 ENVIRONMENT

=over 4

=item C<KUBECONFIG>

Path to kubeconfig file. Default: C<~/.kube/config>

=item C<MCP_K8S_CONTEXT>

Kubeconfig context to use. Default: current-context from kubeconfig.

=item C<MCP_K8S_NAMESPACES>

Comma-separated list of namespaces. Default: auto-discovered from cluster.

=back

=head1 CLAUDE DESKTOP INTEGRATION

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

=seealso

L<MCP::Server>, L<Kubernetes::REST>, L<IO::K8s>, L<MCP::K8s::Permissions>

=cut
