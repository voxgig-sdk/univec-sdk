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

# The alternatives a `$ONE` union offers, or the spec itself when it is not
# one. Every FEATURE option in the generated spec is wrapped
# `['`$ONE`', <type>, '`$NIL`']` (an option a caller may omit), so a walker
# that does not unwrap it sees no types at all.
sub _spec_alts {
  my ($spec) = @_;
  if (Voxgig::Struct::islist($spec) && @$spec
      && defined $spec->[0] && !ref $spec->[0] && '`$ONE`' eq $spec->[0]) {
    return [ @{$spec}[1 .. $#$spec] ];
  }
  return [ $spec ];
}

# Does this spec slot accept a boolean? Either by example (the slot holds a
# real JSON boolean, as `main.kit.optspec` writes `auth.basic: false`) or by
# sentinel (`$BOOLEAN`, which is what a feature option's default widens to).
sub _spec_takes_bool {
  my ($spec) = @_;
  for my $alt (@{ _spec_alts($spec) }) {
    next unless defined $alt;
    return 1 if ref($alt) eq 'Voxgig::Struct::Bool';
    return 1 if !ref($alt) && '`$BOOLEAN`' eq $alt;
  }
  return 0;
}

# PERL HAS NO NATIVE BOOLEAN, so a caller writes `cache => 0` and
# `active => 1` - which is what every shipped test and every perl author
# writes. The vendored struct carries real JTRUE/JFALSE singletons and
# `$BOOLEAN` matches only those, so a plain scalar at a boolean slot is a
# validation ERROR rather than a false. Normalize before validate.
#
# SPEC-DRIVEN, not a list of known key names. This used to coerce any key
# literally named `active`, at any depth, which covered the standard options
# and nothing else - the shipped spec typed no feature option at all. The
# generated option spec types every one of them (secrets' `cache`, netsim's
# `offline`, ...), and a hand-kept name list would have to grow with every
# feature anyone ever adds. The spec already says which slots are boolean, so
# read it: one rule, one place, and a feature added tomorrow is covered.
#
# A slot the spec does not describe is left ALONE. `$OPEN` specs pass unknown
# keys through untouched, and guessing at a value the spec says nothing about
# is how a string "0" would silently become a false.
sub coerce_bools {
  my ($v, $spec) = @_;
  return $v unless defined $spec;

  if (_spec_takes_bool($spec)) {
    if (defined $v && !ref $v) {
      return Voxgig::Struct::jbool($v ? 1 : 0);
    }
    return $v;
  }

  return $v unless Voxgig::Struct::ismap($v);

  # The map alternative of the slot's spec, if it offers one. `$CHILD` is the
  # spec for any key the map does not name.
  my ($mapspec) = grep { Voxgig::Struct::ismap($_) } @{ _spec_alts($spec) };
  return $v unless defined $mapspec;

  my $child = $mapspec->{'`$CHILD`'};
  for my $k (keys %$v) {
    my $sub = exists $mapspec->{$k} ? $mapspec->{$k} : $child;
    next unless defined $sub;
    $v->{$k} = coerce_bools($v->{$k}, $sub);
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
