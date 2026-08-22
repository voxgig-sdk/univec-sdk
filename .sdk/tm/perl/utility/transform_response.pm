# Univec SDK utility: transform_response

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{transform_response} = sub {
  my ($ctx) = @_;
  my $spec = $ctx->{spec};
  my $result = $ctx->{result};
  my $point = $ctx->{point};
  $spec->{step} = 'resform' if $spec;
  return undef if !$result || !$result->{ok};
  my $transform = UnivecHelpers::to_map(UnivecHelpers::gp($point, 'transform'));
  return undef unless $transform;
  my $resform = UnivecHelpers::gp($transform, 'res');
  return undef unless UnivecHelpers::rb_truthy($resform);
  my $resdata = Voxgig::Struct::transform({
    'ok' => Voxgig::Struct::jbool($result->{ok} ? 1 : 0),
    'status' => $result->{status},
    'statusText' => $result->{status_text},
    'headers' => $result->{headers},
    'body' => $result->{body},
    'err' => $result->{err},
    'resdata' => $result->{resdata},
    'resmatch' => $result->{resmatch},
  }, $resform);
  $result->{resdata} = $resdata;
  return $resdata;
};

1;
