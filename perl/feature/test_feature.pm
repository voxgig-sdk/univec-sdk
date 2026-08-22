# Univec SDK test feature

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecTestFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'test';
  $self->{active} = 1;
  $self->{client} = undef;
  $self->{options} = undef;
  $self->{netcalls} = 0;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = $options;

  my $entity = UnivecHelpers::gp($options, 'entity');
  $entity = {} unless Voxgig::Struct::ismap($entity);

  $self->{client}{mode} = 'test';

  # Ensure entity ids are correct.
  Voxgig::Struct::walk($entity, sub {
    my ($key, $val, $parent, $path) = @_;
    if (Voxgig::Struct::islist($path) && 2 == @$path
      && Voxgig::Struct::ismap($val) && defined $key) {
      $val->{id} = $key;
    }
    return $val;
  });

  my $test_self = $self;

  my $respond = sub {
    my ($status, $data, $extra) = @_;
    my $out = {
      'status' => $status,
      'statusText' => 'OK',
      'json' => sub { $data },
      'body' => 'not-used',
    };
    if (Voxgig::Struct::ismap($extra)) {
      $out->{$_} = $extra->{$_} for keys %$extra;
    }
    return ($out, undef);
  };

  my $test_fetcher = sub {
    my ($fctx, $_fullurl, $_fetchdef) = @_;

    my $op = $fctx->{op};
    my $entmap = UnivecHelpers::gp($entity, $op->{entity});
    $entmap = {} unless Voxgig::Struct::ismap($entmap);

    # For single-entity ops (load, remove) with an empty explicit match, fall
    # back to the id the entity client already knows from a prior create/load
    # (in fctx.match / fctx.data). Mirrors the TS mock where param() resolves
    # the id from that accumulated state.
    my $resolve_match = sub {
      my ($explicit) = @_;
      return $explicit
        if Voxgig::Struct::ismap($explicit) && !Voxgig::Struct::isempty($explicit);
      for my $src ($fctx->{match}, $fctx->{data}) {
        next unless defined $src;
        my $v = UnivecHelpers::gp($src, 'id');
        return { 'id' => $v } if defined $v && "$v" ne '__UNDEFINED__';
      }
      return {};
    };

    if ('load' eq $op->{name}) {
      my $args = $test_self->build_args($fctx, $op, $resolve_match->($fctx->{reqmatch}));
      my $found = Voxgig::Struct::select($entmap, $args);
      my $ent = UnivecHelpers::ge($found, 0);
      return $respond->(404, undef, { 'statusText' => 'Not found' })
        unless UnivecHelpers::rb_truthy($ent);
      Voxgig::Struct::delprop($ent, '$KEY');
      my $out = Voxgig::Struct::clone($ent);
      return $respond->(200, $out, undef);
    }
    elsif ('list' eq $op->{name}) {
      my $args = $test_self->build_args($fctx, $op, $fctx->{reqmatch});
      my $found = Voxgig::Struct::select($entmap, $args);
      return $respond->(404, undef, { 'statusText' => 'Not found' })
        unless defined $found && !Voxgig::Struct::is_none($found);
      if (Voxgig::Struct::islist($found)) {
        Voxgig::Struct::delprop($_, '$KEY') for @$found;
      }
      my $out = Voxgig::Struct::clone($found);
      return $respond->(200, $out, undef);
    }
    elsif ('update' eq $op->{name}) {
      # Match the existing entity by id only (or its alias). reqdata also
      # contains the new field values, which would otherwise cause select
      # to filter out the entity we want to update. When reqdata has no id,
      # fall back to the id the entity client carries from a prior
      # create/load (in fctx.match / fctx.data), mirroring the TS mock
      # where param(ctx,'id') resolves from accumulated state.
      my $update_match = {};
      if (Voxgig::Struct::ismap($fctx->{reqdata})) {
        $update_match->{id} = $fctx->{reqdata}{id} if exists $fctx->{reqdata}{id};
        if ($op->{alias}) {
          my $alias_id = UnivecHelpers::gp($op->{alias}, 'id');
          if (defined $alias_id && exists $fctx->{reqdata}{$alias_id}) {
            $update_match->{$alias_id} = $fctx->{reqdata}{$alias_id};
          }
        }
      }
      $update_match = $resolve_match->({}) unless keys %$update_match;
      my $args = $test_self->build_args($fctx, $op, $update_match);
      my $found = Voxgig::Struct::select($entmap, $args);
      my $ent = UnivecHelpers::ge($found, 0);
      if (!defined $ent && Voxgig::Struct::ismap($entmap) && keys %$entmap) {
        for my $k (sort keys %$entmap) {
          if (Voxgig::Struct::ismap($entmap->{$k})) {
            $ent = $entmap->{$k};
            last;
          }
        }
      }
      return $respond->(404, undef, { 'statusText' => 'Not found' })
        unless UnivecHelpers::rb_truthy($ent);
      if (Voxgig::Struct::ismap($ent) && $fctx->{reqdata}) {
        $ent->{$_} = $fctx->{reqdata}{$_} for keys %{ $fctx->{reqdata} };
      }
      Voxgig::Struct::delprop($ent, '$KEY');
      my $out = Voxgig::Struct::clone($ent);
      return $respond->(200, $out, undef);
    }
    elsif ('remove' eq $op->{name}) {
      my $args = $test_self->build_args($fctx, $op, $resolve_match->($fctx->{reqmatch}));
      my $found = Voxgig::Struct::select($entmap, $args);
      my $ent = UnivecHelpers::ge($found, 0);
      # Remove only the first matched entity. If nothing matches,
      # succeed as a no-op rather than erroring.
      if (Voxgig::Struct::ismap($ent)) {
        my $id = UnivecHelpers::gp($ent, 'id');
        Voxgig::Struct::delprop($entmap, $id);
      }
      return $respond->(200, undef, undef);
    }
    elsif ('create' eq $op->{name}) {
      $test_self->build_args($fctx, $op, $fctx->{reqdata});
      my $id = $fctx->{utility}{param}->($fctx, 'id');
      $id = sprintf('%04x%04x%04x%04x',
        int(rand(0x10000)), int(rand(0x10000)),
        int(rand(0x10000)), int(rand(0x10000))) unless defined $id;

      my $ent = Voxgig::Struct::clone($fctx->{reqdata});
      if (Voxgig::Struct::ismap($ent)) {
        $ent->{id} = $id;
        $entmap->{"$id"} = $ent if defined $id && !ref $id;
        Voxgig::Struct::delprop($ent, '$KEY');
        my $out = Voxgig::Struct::clone($ent);
        return $respond->(200, $out, undef);
      }
      return $respond->(200, $ent, undef);
    }
    else {
      return $respond->(404, undef, { 'statusText' => 'Unknown operation' });
    }
  };

  # Optional network behaviour simulation over the mock transport. Enable
  # per test via `SDK->test({ net => { latency => ..., ... } })`. When
  # "net" is absent the mock behaves exactly as before (no wrapping), so
  # existing generated tests are unaffected.
  my $net = UnivecHelpers::gp($options, 'net');
  $net = undef unless Voxgig::Struct::ismap($net);
  $ctx->{utility}{fetcher} = defined $net
    ? $self->make_netsim($net, $test_fetcher)
    : $test_fetcher;
  return;
}

# Wrap a transport with simulated network conditions: latency (fixed or
# {min,max}), a budget of first-N failures ("failTimes" -> "failStatus"),
# first-N connection errors ("errorTimes"), or a hard "offline" outage.
# Counter-driven, so simulations are deterministic across a test.
sub make_netsim {
  my ($self, $net, $inner) = @_;
  $self->{netcalls} = 0;

  my $pick_latency = sub {
    my $l = $net->{latency};
    return 0 unless defined $l;
    if (!ref($l) && Scalar::Util::looks_like_number($l)) {
      return $l < 0 ? 0 : $l;
    }
    return 0 unless Voxgig::Struct::ismap($l);
    my $min = defined $l->{min} ? int($l->{min}) : 0;
    my $max = defined $l->{max} ? int($l->{max}) : $min;
    return $max <= $min ? $min : $min + (($max - $min) >> 1);
  };

  my $do_sleep = sub {
    my ($ms) = @_;
    return if !defined $ms || $ms <= 0;
    if (ref $net->{sleep} eq 'CODE') {
      $net->{sleep}->($ms);
    }
    else {
      UnivecHelpers::sleep_ms($ms);
    }
  };

  my $n = sub {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v) && Scalar::Util::looks_like_number($v);
    return int($v);
  };

  my $test_self = $self;

  return sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    $test_self->{netcalls} += 1;
    my $call = $test_self->{netcalls};

    if (UnivecHelpers::is_true($net->{offline})) {
      $do_sleep->($pick_latency->());
      return (undef, $fctx->make_error('netsim_offline',
        "Simulated network offline (URL was: \"$fullurl\")"));
    }

    if ($call <= $n->($net->{errorTimes})) {
      $do_sleep->($pick_latency->());
      return (undef, $fctx->make_error('netsim_conn',
        "Simulated connection error (call $call)"));
    }

    if ($call <= $n->($net->{failTimes})) {
      $do_sleep->($pick_latency->());
      my $status = defined $net->{failStatus} ? $net->{failStatus} : 503;
      return ({
        'status' => $status,
        'statusText' => 'Simulated Failure',
        'body' => 'not-used',
        'json' => sub { undef },
        'headers' => {},
      }, undef);
    }

    $do_sleep->($pick_latency->());
    return $inner->($fctx, $fullurl, $fetchdef);
  };
}

sub build_args {
  my ($self, $ctx, $op, $args) = @_;
  my $opname = $op->{name};
  my $entname = $ctx->{entity}->get_name;
  my $points = UnivecHelpers::gpath($ctx->{config},
    "entity.$entname.op.$opname.points");
  my $point = UnivecHelpers::ge($points, -1);

  my $params_path = UnivecHelpers::gpath($point, 'args.params');
  my $reqd_params = Voxgig::Struct::select($params_path,
    { 'reqd' => Voxgig::Struct::JTRUE() });
  my $reqd = Voxgig::Struct::transform($reqd_params, ['`$EACH`', '', '`$KEY.name`']);

  my $qand = [];
  my $q = { '`$AND`' => $qand };

  if ($args) {
    my $keys = Voxgig::Struct::keysof($args);
    if ($keys) {
      for my $key (@$keys) {
        my $is_id = ('id' eq $key);
        my $selected = Voxgig::Struct::select($reqd, $key);
        my $is_reqd = !Voxgig::Struct::isempty($selected);

        if ($is_id || $is_reqd) {
          my $v = $ctx->{utility}{param}->($ctx, $key);
          my $ka = $op->{alias} ? UnivecHelpers::gp($op->{alias}, $key) : undef;

          my $qor = [{ $key => $v }];
          push @$qor, { $ka => $v } if defined $ka && !ref $ka;

          push @$qand, { '`$OR`' => $qor };
        }
      }
    }
  }

  $q->{'`$AND`'} = $qand;
  if ($ctx->{ctrl}{explain}) {
    $ctx->{ctrl}{explain}{test} = { 'query' => $q };
  }

  return $q;
}

1;
