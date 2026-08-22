# Univec SDK helpers

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();
use Time::HiRes ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));

package UnivecHelpers;

sub to_map {
  my ($v) = @_;
  return Voxgig::Struct::ismap($v) ? $v : undef;
}

sub to_int {
  my ($v) = @_;
  return -1 unless defined $v && !ref($v) && Scalar::Util::looks_like_number($v);
  return int($v);
}

sub get_ctx_prop {
  my ($m, $key) = @_;
  return undef unless defined $m && ref($m)
    && ((Scalar::Util::reftype($m) // '') eq 'HASH');
  return $m->{$key};
}

# getprop that yields undef (not the NONE sentinel) when absent.
sub gp {
  my $v = Voxgig::Struct::getprop(@_);
  return Voxgig::Struct::is_none($v) ? undef : $v;
}

# getpath that yields undef (not the NONE sentinel) when absent.
sub gpath {
  my $v = Voxgig::Struct::getpath(@_);
  return Voxgig::Struct::is_none($v) ? undef : $v;
}

# getelem that yields undef (not the NONE sentinel) when absent.
sub ge {
  my $v = Voxgig::Struct::getelem(@_);
  return Voxgig::Struct::is_none($v) ? undef : $v;
}

# Ruby/JS truthiness: only nil/null/false are falsy ('' and '0' are truthy).
sub rb_truthy {
  my ($v) = @_;
  return 0 if !defined $v;
  return 0 if Voxgig::Struct::is_none($v) || Voxgig::Struct::is_jnull($v);
  return ($$v ? 1 : 0) if Voxgig::Struct::is_jbool($v);
  return 1;
}

# `== true`: a JSON true, or a plain truthy Perl scalar (1, "x", ...).
sub is_true {
  my ($v) = @_;
  return 0 if !defined $v;
  return ($$v ? 1 : 0) if Voxgig::Struct::is_jbool($v);
  return 0 if ref $v;
  return $v ? 1 : 0;
}

# `== false`: a JSON false, or a defined plain falsy Perl scalar (0, '').
sub is_false {
  my ($v) = @_;
  return 0 if !defined $v;
  return ($$v ? 0 : 1) if Voxgig::Struct::is_jbool($v);
  return 0 if ref $v;
  return $v ? 0 : 1;
}

# Loose scalar equality treating undef/null/NONE as "no value".
sub eqv {
  my ($x, $y) = @_;
  my $dx = defined $x && !Voxgig::Struct::is_none($x) && !Voxgig::Struct::is_jnull($x);
  my $dy = defined $y && !Voxgig::Struct::is_none($y) && !Voxgig::Struct::is_jnull($y);
  return 1 if !$dx && !$dy;
  return 0 if !$dx || !$dy;
  return ("$x" eq "$y") ? 1 : 0;
}

sub now_ms {
  return int(Time::HiRes::time() * 1000);
}

sub sleep_ms {
  my ($ms) = @_;
  Time::HiRes::sleep($ms / 1000.0) if defined $ms && $ms > 0;
}

# Perl cannot distinguish plain 1/0 from JSON booleans; normalize the known
# boolean option slots ("active") so option validation sees real booleans.
sub coerce_bools {
  my ($v) = @_;
  if (Voxgig::Struct::ismap($v)) {
    for my $k (keys %$v) {
      if ('active' eq $k) {
        my $b = $v->{$k};
        if (defined $b && !ref $b) {
          $v->{$k} = Voxgig::Struct::jbool($b ? 1 : 0);
        }
      }
      else {
        coerce_bools($v->{$k});
      }
    }
  }
  elsif (Voxgig::Struct::islist($v)) {
    coerce_bools($_) for @$v;
  }
  return $v;
}

# The vendored struct utility, exposed as a map of named functions so
# callers can reach it via the SDK utility object: utility->{struct}{clone}.
my $STRUCT_FACADE;

sub struct_facade {
  return $STRUCT_FACADE if $STRUCT_FACADE;
  my %f;
  for my $name (qw(
    clone delprop escre escurl filter flatten getdef getelem getpath getprop
    haskey inject isempty isfunc iskey islist ismap isnode items join jsonify
    keysof merge pad parse_json pathify select setpath setprop size slice
    strkey stringify transform typify typename validate walk jm jt
  )) {
    my $ref = Voxgig::Struct->can($name);
    $f{$name} = $ref if $ref;
  }
  $STRUCT_FACADE = \%f;
  return $STRUCT_FACADE;
}

1;
