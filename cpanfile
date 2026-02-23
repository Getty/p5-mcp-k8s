requires 'perl', '5.020';
requires 'Moo', '2.000000';
requires 'MCP', '0.06';
requires 'Kubernetes::REST', '1.000';
requires 'IO::K8s', '1.000';
requires 'JSON::MaybeXS', '1.004000';
requires 'namespace::clean', '0.27';

on test => sub {
  requires 'Test::More', '1.302015';
};
