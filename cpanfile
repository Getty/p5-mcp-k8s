requires 'perl', '5.020';
requires 'Moo';
requires 'MCP', '0.06';
requires 'Kubernetes::REST', '1.002';
requires 'IO::K8s', '1.002';
requires 'JSON::MaybeXS', '1.002000';
requires 'namespace::clean';

on test => sub {
  requires 'Test::More', '0.96';
};
