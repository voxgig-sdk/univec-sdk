# Univec SDK utility: make_response

use strict;
use warnings;

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{make_response} = sub {
  my ($ctx) = @_;
  return ($ctx->{out}{response}, undef) if $ctx->{out}{response};

  my $utility = $ctx->{utility};
  my $spec = $ctx->{spec};
  my $result = $ctx->{result};
  my $response = $ctx->{response};

  return (undef, $ctx->make_error('response_no_spec',
    'Expected context spec property to be defined.')) unless $spec;
  return (undef, $ctx->make_error('response_no_response',
    'Expected context response property to be defined.')) unless $response;
  return (undef, $ctx->make_error('response_no_result',
    'Expected context result property to be defined.')) unless $result;

  $spec->{step} = 'response';
  $utility->{result_basic}->($ctx);
  $utility->{result_headers}->($ctx);
  $utility->{result_body}->($ctx);

  # GraphQL reports failures as a top-level `errors` array under HTTP 200,
  # so result_basic's status check never sees them. Lift them here, before
  # the response transform tries to unwrap data that is not there.
  $utility->{graphql_errors}->($ctx);

  $utility->{transform_response}->($ctx);

  $result->{ok} = 1 if !defined $result->{err};
  $ctx->{ctrl}{explain}{result} = $result if $ctx->{ctrl}{explain};

  return ($response, undef);
};

1;
