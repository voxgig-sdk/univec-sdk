# Univec SDK operation

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/helpers.pm"));

package UnivecOperation;

sub new {
  my ($class, $opmap) = @_;
  $opmap = {} unless defined $opmap;

  my $e = UnivecHelpers::gp($opmap, 'entity');
  my $entity = (defined $e && !ref $e && $e ne '') ? $e : '_';

  my $n = UnivecHelpers::gp($opmap, 'name');
  my $name = (defined $n && !ref $n && $n ne '') ? $n : '_';

  my $i = UnivecHelpers::gp($opmap, 'input');
  my $input = (defined $i && !ref $i && $i ne '') ? $i : '_';

  my $points = [];
  my $raw_points = UnivecHelpers::gp($opmap, 'points');
  if (Voxgig::Struct::islist($raw_points)) {
    push @$points, grep { Voxgig::Struct::ismap($_) } @$raw_points;
  }

  my $raw_alias = UnivecHelpers::gp($opmap, 'alias');
  my $alias = Voxgig::Struct::ismap($raw_alias) ? $raw_alias : undef;

  return bless {
    entity => $entity,
    name   => $name,
    input  => $input,
    points => $points,
    alias  => $alias,
  }, $class;
}

1;
