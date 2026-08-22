# Univec SDK utility: prepare_params

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

$REGISTRY{prepare_params} = sub {
  my ($ctx) = @_;
  my $utility = $ctx->{utility};
  my $point = $ctx->{point};
  my $params = [];
  if ($point) {
    my $args = UnivecHelpers::gp($point, 'args');
    if (Voxgig::Struct::ismap($args)) {
      my $p = UnivecHelpers::gp($args, 'params');
      $params = $p if Voxgig::Struct::islist($p);
    }
  }
  my $out = {};
  for my $pd (@$params) {
    my $val = $utility->{param}->($ctx, $pd);
    if (UnivecHelpers::rb_truthy($val) && Voxgig::Struct::ismap($pd)) {
      my $name = UnivecHelpers::gp($pd, 'name');
      $out->{$name} = $val if defined $name && !ref $name && '' ne $name;
    }
  }
  return $out;
};

1;
