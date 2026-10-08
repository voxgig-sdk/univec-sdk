# Univec SDK utility: done

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{done} = sub {
  my ($ctx) = @_;
  $REGISTRY{clean_explain}->($ctx);
  if ($ctx->{result} && $ctx->{result}{ok}) {
    return $ctx->{result}{resdata};
  }
  # On error, make_error dies with the exception (or, when throw_err is
  # disabled, returns the bare result data). Propagate its value.
  return $ctx->{utility}{make_error}->($ctx, undef);
};

# The caller's own hash is the explain record (the control is built from it,
# and a stream copies only its ctrl), so the cleaned copy is written back
# INTO it: assigning a fresh hash would leave the caller holding the raw one.
$REGISTRY{clean_explain} = sub {
  my ($ctx) = @_;
  my $explain = $ctx->{ctrl}{explain};
  return unless Voxgig::Struct::ismap($explain);
  my $cleaned = $ctx->{utility}{clean}->($ctx, $explain);
  if (Voxgig::Struct::ismap($cleaned)
    && Scalar::Util::refaddr($cleaned) != Scalar::Util::refaddr($explain)) {
    %$explain = %$cleaned;
  }
  # A copy: with clean off, explain.result is the live result make_error reads.
  my $er = $explain->{result};
  if (Voxgig::Struct::ismap($er)) {
    my %pruned = %$er;
    delete $pruned{err};
    $explain->{result} = \%pruned;
  }
  return;
};

1;
