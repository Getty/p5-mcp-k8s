requires 'perl', '5.020';
requires 'IO::K8s', '1.109';
requires 'JSON::MaybeXS', '1.002000';
requires 'Kubernetes::REST', '1.109';
requires 'MCP', '0.15';
requires 'Moo';
requires 'namespace::clean';

on test => sub {
  requires 'File::Temp';
  requires 'Test::More', '0.96';
};
