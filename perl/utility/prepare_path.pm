# Univec SDK utility: prepare_path

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

$REGISTRY{prepare_path} = sub {
  my ($ctx) = @_;
  my $point = $ctx->{point};
  my $parts = [];
  if ($point) {
    my $p = UnivecHelpers::gp($point, 'parts');
    $parts = $p if Voxgig::Struct::islist($p);
  }
  return Voxgig::Struct::join($parts, '/', 1);
};

1;
