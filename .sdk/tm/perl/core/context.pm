# Univec SDK context

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/helpers.pm"));
require(Cwd::abs_path("$__dir/control.pm"));
require(Cwd::abs_path("$__dir/operation.pm"));
require(Cwd::abs_path("$__dir/spec.pm"));
require(Cwd::abs_path("$__dir/result.pm"));
require(Cwd::abs_path("$__dir/response.pm"));
require(Cwd::abs_path("$__dir/error.pm"));

package UnivecContext;

sub new {
  my ($class, $ctxmap, $basectx) = @_;
  $ctxmap = {} unless defined $ctxmap;

  my $self = bless {}, $class;

  $self->{id} = 'C' . (10000000 + int(rand(90000000)));
  $self->{out} = {};

  my $gcp = \&UnivecHelpers::get_ctx_prop;

  $self->{client} = $gcp->($ctxmap, 'client');
  $self->{client} = $basectx->{client} if !defined $self->{client} && $basectx;

  $self->{utility} = $gcp->($ctxmap, 'utility');
  $self->{utility} = $basectx->{utility} if !defined $self->{utility} && $basectx;

  $self->{ctrl} = UnivecControl->new();
  my $ctrl_raw = $gcp->($ctxmap, 'ctrl');
  if (Voxgig::Struct::ismap($ctrl_raw)) {
    $self->{ctrl}{throw_err} = $ctrl_raw->{throw} if exists $ctrl_raw->{throw};
    $self->{ctrl}{explain} = $ctrl_raw->{explain} if Voxgig::Struct::ismap($ctrl_raw->{explain});
    $self->{ctrl}{actor} = $ctrl_raw->{actor} if exists $ctrl_raw->{actor};
    $self->{ctrl}{paging} = $ctrl_raw->{paging} if Voxgig::Struct::ismap($ctrl_raw->{paging});
  }
  elsif ($basectx && $basectx->{ctrl}) {
    $self->{ctrl} = $basectx->{ctrl};
  }

  my $m = $gcp->($ctxmap, 'meta');
  $self->{meta} = Voxgig::Struct::ismap($m) ? $m : (($basectx && $basectx->{meta}) || {});

  my $cfg = $gcp->($ctxmap, 'config');
  $self->{config} = Voxgig::Struct::ismap($cfg) ? $cfg : ($basectx ? $basectx->{config} : undef);

  my $eo = $gcp->($ctxmap, 'entopts');
  $self->{entopts} = Voxgig::Struct::ismap($eo) ? $eo : ($basectx ? $basectx->{entopts} : undef);

  my $o = $gcp->($ctxmap, 'options');
  $self->{options} = Voxgig::Struct::ismap($o) ? $o : ($basectx ? $basectx->{options} : undef);

  my $e = $gcp->($ctxmap, 'entity');
  $self->{entity} = defined $e ? $e : ($basectx ? $basectx->{entity} : undef);

  my $s = $gcp->($ctxmap, 'shared');
  $self->{shared} = Voxgig::Struct::ismap($s) ? $s : ($basectx ? $basectx->{shared} : undef);

  my $om = $gcp->($ctxmap, 'opmap');
  $self->{opmap} = Voxgig::Struct::ismap($om) ? $om : (($basectx && $basectx->{opmap}) || {});

  $self->{data} = UnivecHelpers::to_map($gcp->($ctxmap, 'data')) || {};
  $self->{reqdata} = UnivecHelpers::to_map($gcp->($ctxmap, 'reqdata')) || {};
  $self->{match} = UnivecHelpers::to_map($gcp->($ctxmap, 'match')) || {};
  $self->{reqmatch} = UnivecHelpers::to_map($gcp->($ctxmap, 'reqmatch')) || {};

  my $pt = $gcp->($ctxmap, 'point');
  $self->{point} = Voxgig::Struct::ismap($pt) ? $pt : ($basectx ? $basectx->{point} : undef);

  my $sp = $gcp->($ctxmap, 'spec');
  $self->{spec} = (Scalar::Util::blessed($sp) && $sp->isa('UnivecSpec'))
    ? $sp : ($basectx ? $basectx->{spec} : undef);

  my $r = $gcp->($ctxmap, 'result');
  $self->{result} = (Scalar::Util::blessed($r) && $r->isa('UnivecResult'))
    ? $r : ($basectx ? $basectx->{result} : undef);

  my $rp = $gcp->($ctxmap, 'response');
  $self->{response} = (Scalar::Util::blessed($rp) && $rp->isa('UnivecResponse'))
    ? $rp : ($basectx ? $basectx->{response} : undef);

  my $opname = $gcp->($ctxmap, 'opname');
  $opname = '' unless defined $opname && !ref $opname;
  $self->{op} = $self->resolve_op($opname);

  return $self;
}

sub resolve_op {
  my ($self, $opname) = @_;

  # Cache key is `<entity>:<opname>` so two entities with the same op
  # (e.g. both have a "list") get distinct cached Operations. Keying
  # on opname alone caused the first-resolved entity's points to be
  # served to every subsequent entity's call.
  my $ent = $self->{entity};
  my $entname = (Scalar::Util::blessed($ent) && $ent->can('get_name')) ? $ent->get_name : '_';
  my $cache_key = "$entname:$opname";
  return $self->{opmap}{$cache_key} if $self->{opmap}{$cache_key};
  return UnivecOperation->new({}) if '' eq $opname;

  my $opcfg = UnivecHelpers::gpath($self->{config}, "entity.$entname.op.$opname");

  my $input = ($opname eq 'update' || $opname eq 'create') ? 'data' : 'match';

  my $points = [];
  if (Voxgig::Struct::ismap($opcfg)) {
    my $t = UnivecHelpers::gp($opcfg, 'points');
    $points = $t if Voxgig::Struct::islist($t);
  }

  my $op = UnivecOperation->new({
    entity => $entname,
    name   => $opname,
    input  => $input,
    points => $points,
  });
  $self->{opmap}{$cache_key} = $op;
  return $op;
}

sub make_error {
  my ($self, $code, $msg) = @_;
  return UnivecError->new($code, $msg, $self);
}

1;
