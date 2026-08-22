# Univec SDK utility: result_headers

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{result_headers} = sub {
  my ($ctx) = @_;
  my $response = $ctx->{response};
  my $result = $ctx->{result};
  if ($result) {
    if ($response && Voxgig::Struct::ismap($response->{headers})) {
      $result->{headers} = $response->{headers};
    }
    else {
      $result->{headers} = {};
    }
  }
  return $result;
};

1;
