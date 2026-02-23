package MCP::K8s::Permissions;
# ABSTRACT: RBAC discovery and permission checking for Kubernetes

use Moo;
use Carp qw( croak );
use Scalar::Util qw( weaken );
use namespace::clean;

our $VERSION = '0.001';

has api => (
  is       => 'ro',
  required => 1,
  weak_ref => 1,
);

has namespaces => (
  is       => 'ro',
  required => 1,
);

has _rules => (
  is      => 'rw',
  default => sub { {} },
);

sub discover {
  my ($self) = @_;

  my %rules;

  for my $ns (@{ $self->namespaces }) {
    my $ns_rules = eval { $self->_discover_namespace($ns) };
    if ($@) {
      warn "Failed to discover permissions for namespace '$ns': $@";
      next;
    }
    $rules{$ns} = $ns_rules;
  }

  # Also try cluster-scoped discovery (empty namespace)
  my $cluster_rules = eval { $self->_discover_namespace('') };
  if (!$@ && keys %$cluster_rules) {
    $rules{''} = $cluster_rules;
  }

  $self->_rules(\%rules);
  return $self;
}

sub _discover_namespace {
  my ($self, $namespace) = @_;

  my $review = $self->api->new_object('SelfSubjectRulesReview', {
    spec => {
      namespace => $namespace,
    },
  });

  my $result = $self->api->create($review);
  my $status = $result->status;
  return {} unless $status;

  my %ns_rules;
  my $resource_rules = $status->resourceRules // [];

  for my $rule (@$resource_rules) {
    my @verbs     = @{ $rule->verbs // [] };
    my @resources = @{ $rule->resources // [] };

    for my $resource (@resources) {
      # Skip subresources for now (e.g. "pods/log")
      # We handle pods/log specifically in the logs tool
      next if $resource =~ m{/} && $resource ne 'pods/log';

      for my $verb (@verbs) {
        $ns_rules{$resource}{$verb} = 1;
        # Wildcard verb means all standard verbs
        if ($verb eq '*') {
          $ns_rules{$resource}{$_} = 1 for qw(get list watch create update patch delete);
        }
      }
    }

    # Wildcard resource means all resources for these verbs
    if (grep { $_ eq '*' } @resources) {
      for my $verb (@verbs) {
        $ns_rules{'*'}{$verb} = 1;
        if ($verb eq '*') {
          $ns_rules{'*'}{$_} = 1 for qw(get list watch create update patch delete);
        }
      }
    }
  }

  return \%ns_rules;
}

sub can_do {
  my ($self, $verb, $resource_plural, $namespace) = @_;
  $namespace //= '';

  my $ns_rules = $self->_rules->{$namespace};
  return 0 unless $ns_rules;

  # Check explicit resource permission
  return 1 if $ns_rules->{$resource_plural} && $ns_rules->{$resource_plural}{$verb};
  # Check wildcard verb on explicit resource
  return 1 if $ns_rules->{$resource_plural} && $ns_rules->{$resource_plural}{'*'};
  # Check wildcard resource
  return 1 if $ns_rules->{'*'} && $ns_rules->{'*'}{$verb};
  return 1 if $ns_rules->{'*'} && $ns_rules->{'*'}{'*'};

  return 0;
}

sub allowed_resources {
  my ($self, $verb, $namespace) = @_;
  $namespace //= '';

  my $ns_rules = $self->_rules->{$namespace};
  return () unless $ns_rules;

  my @resources;
  for my $resource (sort keys %$ns_rules) {
    next if $resource eq '*';
    next if $resource =~ m{/};  # skip subresources
    if ($ns_rules->{$resource}{$verb}
        || $ns_rules->{$resource}{'*'}
        || ($ns_rules->{'*'} && ($ns_rules->{'*'}{$verb} || $ns_rules->{'*'}{'*'}))) {
      push @resources, $resource;
    }
  }

  # If wildcard resource is allowed, indicate that
  if ($ns_rules->{'*'} && ($ns_rules->{'*'}{$verb} || $ns_rules->{'*'}{'*'})) {
    unshift @resources, '*' unless grep { $_ eq '*' } @resources;
  }

  return @resources;
}

sub allowed_namespaces {
  my ($self) = @_;
  return grep { $_ ne '' } sort keys %{ $self->_rules };
}

sub can_read_logs {
  my ($self, $namespace) = @_;
  $namespace //= '';
  my $ns_rules = $self->_rules->{$namespace};
  return 0 unless $ns_rules;

  # Check pods/log get permission
  return 1 if $ns_rules->{'pods/log'} && ($ns_rules->{'pods/log'}{'get'} || $ns_rules->{'pods/log'}{'*'});
  # Wildcard resource covers subresources too
  return 1 if $ns_rules->{'*'} && ($ns_rules->{'*'}{'get'} || $ns_rules->{'*'}{'*'});
  # pods wildcard often implies pods/log
  return 1 if $ns_rules->{'pods'} && ($ns_rules->{'pods'}{'get'} || $ns_rules->{'pods'}{'*'});

  return 0;
}

sub summary {
  my ($self) = @_;

  my @lines;
  push @lines, "# Kubernetes RBAC Permissions\n";

  my @namespaces = $self->allowed_namespaces;
  unless (@namespaces) {
    push @lines, "No namespace permissions discovered.";
    return join("\n", @lines);
  }

  for my $ns (@namespaces) {
    push @lines, "## Namespace: $ns\n";

    my $ns_rules = $self->_rules->{$ns};
    if ($ns_rules->{'*'} && $ns_rules->{'*'}{'*'}) {
      push @lines, "Full access (all resources, all verbs)\n";
      next;
    }

    my %by_verb;
    for my $resource (sort keys %$ns_rules) {
      next if $resource eq '*';
      for my $verb (sort keys %{ $ns_rules->{$resource} }) {
        next if $verb eq '*';
        push @{ $by_verb{$verb} }, $resource;
      }
      if ($ns_rules->{$resource}{'*'}) {
        push @{ $by_verb{'all verbs'} }, $resource;
      }
    }

    for my $verb (sort keys %by_verb) {
      my @resources = @{ $by_verb{$verb} };
      push @lines, "- **$verb**: " . join(', ', @resources);
    }

    push @lines, "";
  }

  # Cluster-scoped
  if (my $cluster = $self->_rules->{''}) {
    push @lines, "## Cluster-scoped\n";
    if ($cluster->{'*'} && $cluster->{'*'}{'*'}) {
      push @lines, "Full cluster access (all resources, all verbs)\n";
    } else {
      for my $resource (sort keys %$cluster) {
        next if $resource eq '*';
        my @verbs = sort keys %{ $cluster->{$resource} };
        push @lines, "- **$resource**: " . join(', ', @verbs);
      }
      push @lines, "";
    }
  }

  return join("\n", @lines);
}

1;
