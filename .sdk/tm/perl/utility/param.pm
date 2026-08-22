# Univec SDK utility: param

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

$REGISTRY{param} = sub {
  my ($ctx, $paramdef) = @_;
  my $point = $ctx->{point};
  my $spec = $ctx->{spec};
  my $match_val = $ctx->{match};
  my $reqmatch = $ctx->{reqmatch};
  my $data = $ctx->{data};
  my $reqdata = $ctx->{reqdata};

  my $pt = Voxgig::Struct::typify($paramdef);
  my $key;
  if (($pt & Voxgig::Struct::T_string()) > 0) {
    $key = $paramdef;
  }
  else {
    my $k = UnivecHelpers::gp($paramdef, 'name');
    $key = (defined $k && !ref $k) ? $k : '';
  }

  my $akey = '';
  if ($point) {
    my $alias_map = UnivecHelpers::to_map(UnivecHelpers::gp($point, 'alias'));
    if ($alias_map) {
      my $ak = UnivecHelpers::gp($alias_map, $key);
      $akey = $ak if defined $ak && !ref $ak;
    }
  }

  my $val = UnivecHelpers::gp($reqmatch, $key);
  $val = UnivecHelpers::gp($match_val, $key) if !defined $val;

  if (!defined $val && '' ne $akey) {
    $spec->{alias}{$akey} = $key if $spec;
    $val = UnivecHelpers::gp($reqmatch, $akey);
  }

  $val = UnivecHelpers::gp($reqdata, $key) if !defined $val;
  $val = UnivecHelpers::gp($data, $key) if !defined $val;

  if (!defined $val && '' ne $akey) {
    $val = UnivecHelpers::gp($reqdata, $akey);
    $val = UnivecHelpers::gp($data, $akey) if !defined $val;
  }

  return $val;
};

1;
