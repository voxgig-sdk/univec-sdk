# Univec SDK utility: done

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

$REGISTRY{done} = sub {
  my ($ctx) = @_;
  my $ctrl = $ctx->{ctrl};
  if ($ctrl->{explain}) {
    $ctrl->{explain} = $ctx->{utility}{clean}->($ctx, $ctrl->{explain});
    my $er = $ctrl->{explain}{result};
    delete $er->{err} if Voxgig::Struct::ismap($er);
  }
  if ($ctx->{result} && $ctx->{result}{ok}) {
    return $ctx->{result}{resdata};
  }
  # On error, make_error dies with the exception (or, when throw_err is
  # disabled, returns the bare result data). Propagate its value.
  return $ctx->{utility}{make_error}->($ctx, undef);
};

1;
