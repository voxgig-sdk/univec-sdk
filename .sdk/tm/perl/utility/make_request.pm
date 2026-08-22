# Univec SDK utility: make_request

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/response.pm"));
require(Cwd::abs_path("$__dir/../core/result.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{make_request} = sub {
  my ($ctx) = @_;
  return ($ctx->{out}{request}, undef) if $ctx->{out}{request};

  my $spec = $ctx->{spec};
  my $utility = $ctx->{utility};
  my $response = UnivecResponse->new({});
  my $result = UnivecResult->new({});
  $ctx->{result} = $result;

  return (undef, $ctx->make_error('request_no_spec',
    'Expected context spec property to be defined.')) unless $spec;

  my ($fetchdef, $err) = $utility->{make_fetch_def}->($ctx);
  if ($err) {
    $response->{err} = $err;
    $ctx->{response} = $response;
    $spec->{step} = 'postrequest';
    return ($response, undef);
  }

  $ctx->{ctrl}{explain}{fetchdef} = $fetchdef if $ctx->{ctrl}{explain};

  $spec->{step} = 'prerequest';
  my $url = defined $fetchdef->{url} ? $fetchdef->{url} : '';
  my ($fetched, $fetch_err) = $utility->{fetcher}->($ctx, $url, $fetchdef);

  if ($fetch_err) {
    $response->{err} = $fetch_err;
  }
  elsif (!defined $fetched) {
    $response = UnivecResponse->new({
      'err' => $ctx->make_error('request_no_response', 'response: undefined'),
    });
  }
  elsif (Voxgig::Struct::ismap($fetched)) {
    $response = UnivecResponse->new($fetched);
  }
  else {
    $response->{err} = $ctx->make_error('request_invalid_response', 'response: invalid type');
  }

  $spec->{step} = 'postrequest';
  $ctx->{response} = $response;
  return ($response, undef);
};

1;
