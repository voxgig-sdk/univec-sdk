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

  # No default: an op name outside the convention resolves to no method,
  # exactly as the ts reference (`methodMap[key]` is undefined there).
  # The silent-pass inline runner hid a stray 'GET' fallback here; the
  # shared corpus (prepareMethod, opname "bad" -> null) pins it now.
  my $opname = $ctx->{op} ? $ctx->{op}{name} : undef;
  return undef unless defined $opname && !ref $opname;
  return $METHOD_MAP{$opname};
};

# Whether a comma-separated allow option names the item: whole names, any case.
sub allowed {
  my ($names, $item) = @_;
  return 0 unless defined $item && !ref $item && '' ne $item;
  return 0 unless defined $names && !ref $names;
  my $want = uc $item;
  for my $name (split /,/, $names) {
    (my $trimmed = $name) =~ s/^\s+|\s+$//g;
    return 1 if uc($trimmed) eq $want;
  }
  return 0;
}

1;
