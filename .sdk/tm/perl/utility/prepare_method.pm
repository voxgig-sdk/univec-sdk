# Univec SDK utility: prepare_method

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecUtilities;

our %REGISTRY;

my %METHOD_MAP = (
  'create' => 'POST',
  'update' => 'PUT',
  'load'   => 'GET',
  'list'   => 'GET',
  'remove' => 'DELETE',
  'patch'  => 'PATCH',
);

$REGISTRY{prepare_method} = sub {
  my ($ctx) = @_;

  # The API definition is authoritative: a POST-only or PATCH-based API
  # exposes `update` as POST or PATCH, not the PUT the op name implies.
  # Only fall back to the op-name convention when the point has no method.
  my $point = $ctx->{point};
  if ($point) {
    my $pm = UnivecHelpers::gp($point, 'method');
    return uc($pm) if defined $pm && !ref($pm) && '' ne $pm;
  }

  my $m = $METHOD_MAP{ $ctx->{op}{name} };
  return defined $m ? $m : 'GET';
};

1;
