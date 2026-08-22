# Univec SDK utility: result_basic

use strict;
use warnings;

use Scalar::Util ();

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{result_basic} = sub {
  my ($ctx) = @_;
  my $response = $ctx->{response};
  my $result = $ctx->{result};
  if ($result && $response) {
    $result->{status} = $response->{status};
    $result->{status_text} = $response->{status_text};
    if (($result->{status} || 0) >= 400) {
      my $msg = "request: $result->{status}: $result->{status_text}";
      if ($result->{err}) {
        my $prev = (Scalar::Util::blessed($result->{err})
          && $result->{err}->isa('UnivecError'))
          ? $result->{err}{msg} : "$result->{err}";
        $result->{err} = $ctx->make_error('request_status', "$prev: $msg");
      }
      else {
        $result->{err} = $ctx->make_error('request_status', $msg);
      }
    }
    elsif ($response->{err}) {
      $result->{err} = $response->{err};
    }
  }
  return $result;
};

1;
