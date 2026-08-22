# Univec SDK utility: prepare_query

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

$REGISTRY{prepare_query} = sub {
  my ($ctx) = @_;
  my $point = $ctx->{point};
  my $reqmatch = $ctx->{reqmatch} || {};
  my $params = [];
  if ($point) {
    my $p = UnivecHelpers::gp($point, 'params');
    $params = $p if Voxgig::Struct::islist($p);
  }
  my $out = {};
  my $items = Voxgig::Struct::items($reqmatch);
  if ($items) {
    for my $item (@$items) {
      my ($key, $val) = @$item;
      next unless UnivecHelpers::rb_truthy($val) && defined $key && !ref $key;
      next if grep { defined $_ && !ref $_ && $_ eq $key } @$params;
      $out->{$key} = $val;
    }
  }
  return $out;
};

1;
