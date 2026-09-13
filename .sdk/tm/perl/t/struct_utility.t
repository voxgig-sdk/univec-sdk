#!perl
# VERSION: @voxgig/struct 0.1.1 (vendored; driven via t/omni.pm)
#
# Univec SDK struct utility test
#
# Corpus sections run through the vendored omni runner, via the resolver
# in t/omni.pm (struct-runner shape over native Voxgig::Omni;
# t/struct_runner.pm is retired - see docs/design/vendor-tag-rollout.md).
# This file only says WHICH subject answers each group and with which
# flags - the entry loop, the comparison, the error and `match` handling
# all live in the runner, identically for every port. Flags mirror
# canonical (tm/ts/test/utility/StructUtility.test.ts).

use 5.018;
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Scalar::Util ();
use File::Basename ();
use Cwd ();

use UnivecSDK;

require(Cwd::abs_path("$FindBin::Bin/omni.pm"));

my $corpus_path = Cwd::abs_path("$FindBin::Bin/../../.sdk/test/test.json");

unless (defined $corpus_path && -e $corpus_path) {
  plan skip_all => "Corpus file not found";
}

# The struct corpus drives the LIVE SDK's struct utilities, as ts does.
my $client = UnivecSDK->test(undef, undef);
my $runner = UnivecOmni::make_runner($corpus_path, $client);
my $R = $runner->('struct');

my $struct_spec = $R->{spec};
my $runset = $R->{runset};
my $runsetflags = $R->{runsetflags};

# The struct facade exposed via the client utility carries the full API.
my $S = $client->get_utility->{struct};

for my $meth (qw(
    clone delprop escre escurl filter flatten getdef getelem getpath getprop
    haskey inject isempty isfunc iskey islist ismap isnode items join jsonify
    keysof merge pad pathify select setpath setprop size slice strkey stringify
    transform typify typename validate walk jm jt
)) {
  ok(ref $S->{$meth} eq 'CODE', "utility struct facade has $meth");
}

my $jbool = \&Voxgig::Struct::jbool;
my $NULLMARK = UnivecOmni::NULLMARK();

# Canonical comparison string for the single-entry cases below (they are
# not sets, so they are compared here rather than by the runner): sorted
# map keys, so key order is not significant.
sub canon {
  my ($v) = @_;
  return Voxgig::Struct::_stringify_inner($v, 1);
}

# Each group is one Test::More assertion, so a failure names the group and
# the entry (omni's message carries the index, the entry and both values).
sub group {
  my ($label, $testspec, $flags, $subject) = @_;
  unless (ref($testspec) eq 'HASH' && ref($testspec->{set}) eq 'ARRAY') {
    fail("$label: corpus group missing");
    return 0;
  }
  my $ok = eval { $runsetflags->($testspec, $flags, $subject); 1 };
  if ($ok) {
    pass($label);
    return 1;
  }
  my $err = $@;
  fail($label);
  diag("$label: $err");
  return 0;
}

# One group, omni's default flags (`null` on).
sub grun {
  my ($label, $testspec, $subject) = @_;
  return group($label, $testspec, {}, $subject);
}

# One group with explicit flags.
sub grunflags {
  my ($label, $testspec, $flags, $subject) = @_;
  return group($label, $testspec, $flags, $subject);
}


# ===========================================================================
# minor
# ===========================================================================

my $minor = $struct_spec->{minor};

grun('minor.isnode', $minor->{isnode}, sub { $jbool->($S->{isnode}->($_[0])) });
grun('minor.ismap', $minor->{ismap}, sub { $jbool->($S->{ismap}->($_[0])) });
grun('minor.islist', $minor->{islist}, sub { $jbool->($S->{islist}->($_[0])) });

grunflags('minor.iskey', $minor->{iskey}, { null => 0 },
  sub { $jbool->($S->{iskey}->($_[0])) });

grunflags('minor.strkey', $minor->{strkey}, { null => 0 },
  sub { $S->{strkey}->($_[0]) });

grunflags('minor.isempty', $minor->{isempty}, { null => 0 },
  sub { $jbool->($S->{isempty}->($_[0])) });

grun('minor.isfunc', $minor->{isfunc}, sub { $jbool->($S->{isfunc}->($_[0])) });

grunflags('minor.clone', $minor->{clone}, { null => 0 },
  sub { $S->{clone}->($_[0]) });

# The corpus names the predicate; the test file supplies it.
my %checkmap = (
  gt3 => sub { $_[0][1] > 3 },
  lt3 => sub { $_[0][1] < 3 },
);
grun('minor.filter', $minor->{filter},
  sub { $S->{filter}->($_[0]{val}, $checkmap{ $_[0]{check} }) });

grun('minor.flatten', $minor->{flatten},
  sub { $S->{flatten}->($_[0]{val}, $_[0]{depth}) });

grun('minor.escre', $minor->{escre}, sub { $S->{escre}->($_[0]) });
grun('minor.escurl', $minor->{escurl}, sub { $S->{escurl}->($_[0]) });

# An entry with NO `val` is canonical stringify(undefined) == ''; a
# NULLMARK val (null flag on) is a real JSON null to stringify.
grun('minor.stringify', $minor->{stringify}, sub {
  my ($in) = @_;
  return '' if ref($in) ne 'HASH' || !exists $in->{val};
  my $val = $in->{val};
  my $isnul = defined $val && !ref $val && $val eq $NULLMARK;
  return $S->{stringify}->($isnul ? 'null' : $val, $in->{max});
});

grunflags('minor.jsonify', $minor->{jsonify}, { null => 0 },
  sub { $S->{jsonify}->($_[0]{val}, $_[0]{flags}) });

# `null: true`, so an absent path arrives as NULLMARK and the rendered
# path has to be put back the way canonical renders a real undefined
# (ported from upstream struct's t/struct.t).
grunflags('minor.pathify', $minor->{pathify}, { null => 1 }, sub {
  my ($in) = @_;
  return '<unknown-path>' if ref($in) ne 'HASH' || !exists $in->{path};
  my $raw = $in->{path};
  my $isnul = defined $raw && !ref $raw && $raw eq $NULLMARK;
  my $path = $isnul ? undef : $raw;
  my $str = $S->{pathify}->($path, $in->{from});
  $str =~ s/\Q$NULLMARK\E\.//;
  $str =~ s/>/:null>/g if $isnul;
  return $str;
});

grun('minor.items', $minor->{items}, sub { $S->{items}->($_[0]) });

# `alt` is omitted where the corpus omits it: passing an explicit undef is
# a different call, and getelem/getprop differ on whether a NULL alt
# counts.
grunflags('minor.getelem', $minor->{getelem}, { null => 0 }, sub {
  my ($in) = @_;
  my $alt = $in->{alt};
  return (!defined $alt || Voxgig::Struct::is_jnull($alt))
    ? $S->{getelem}->($in->{val}, $in->{key})
    : $S->{getelem}->($in->{val}, $in->{key}, $alt);
});

grunflags('minor.getprop', $minor->{getprop}, { null => 0 }, sub {
  my ($in) = @_;
  return exists $in->{alt}
    ? $S->{getprop}->($in->{val}, $in->{key}, $in->{alt})
    : $S->{getprop}->($in->{val}, $in->{key});
});

grun('minor.setprop', $minor->{setprop},
  sub { $S->{setprop}->($_[0]{parent}, $_[0]{key}, $_[0]{val}) });

grun('minor.delprop', $minor->{delprop},
  sub { $S->{delprop}->($_[0]{parent}, $_[0]{key}) });

grunflags('minor.haskey', $minor->{haskey}, { null => 0 },
  sub { $jbool->($S->{haskey}->($_[0]{src}, $_[0]{key})) });

grun('minor.keysof', $minor->{keysof}, sub { $S->{keysof}->($_[0]) });

grunflags('minor.join', $minor->{join}, { null => 0 },
  sub { $S->{join}->($_[0]{val}, $_[0]{sep}, $_[0]{url}) });

grun('minor.typename', $minor->{typename}, sub { $S->{typename}->($_[0]) });

grunflags('minor.typify', $minor->{typify}, { null => 0 },
  sub { $S->{typify}->($_[0]) });

grunflags('minor.size', $minor->{size}, { null => 0 },
  sub { $S->{size}->($_[0]) });

grunflags('minor.slice', $minor->{slice}, { null => 0 },
  sub { $S->{slice}->($_[0]{val}, $_[0]{start}, $_[0]{end}) });

grunflags('minor.pad', $minor->{pad}, { null => 0 },
  sub { $S->{pad}->($_[0]{val}, $_[0]{pad}, $_[0]{char}) });

# setpath rewrites `store` IN PLACE, and the entries assert that rewrite
# through `match.args` - the resolver's in-place model conversion is what
# lets the runner see it (t/omni.pm, decision 2).
grunflags('minor.setpath', $minor->{setpath}, { null => 0 },
  sub { $S->{setpath}->($_[0]{store}, $_[0]{path}, $_[0]{val}) });


# ===========================================================================
# nullsem - does a PRESENT key holding a JSON null read as "no value"?
# Opt-in per target (create-sdkgen ships it; an older project corpus may
# predate it - the skip says so OUT LOUD rather than passing vacuously).
# All lanes {null: 0}, so the stored nulls are REAL (JNULL after the model
# conversion), not the NULLMARK string.
# ===========================================================================

SKIP: {
  my $nullsem = (ref($struct_spec) eq 'HASH') ? $struct_spec->{nullsem} : undef;
  skip 'corpus predates struct.nullsem - refresh .sdk/test/struct from create-sdkgen', 5
    unless ref($nullsem) eq 'HASH';

  grunflags('nullsem.getprop', $nullsem->{getprop}, { null => 0 }, sub {
    my ($in) = @_;
    return exists $in->{alt}
      ? $S->{getprop}->($in->{val}, $in->{key}, $in->{alt})
      : $S->{getprop}->($in->{val}, $in->{key});
  });

  grunflags('nullsem.getelem', $nullsem->{getelem}, { null => 0 }, sub {
    my ($in) = @_;
    return exists $in->{alt}
      ? $S->{getelem}->($in->{val}, $in->{key}, $in->{alt})
      : $S->{getelem}->($in->{val}, $in->{key});
  });

  grunflags('nullsem.getpath', $nullsem->{getpath}, { null => 0 },
    sub { $S->{getpath}->($_[0]{store}, $_[0]{path}) });

  grunflags('nullsem.haskey', $nullsem->{haskey}, { null => 0 },
    sub { $jbool->($S->{haskey}->($_[0]{src}, $_[0]{key})) });

  grunflags('nullsem.keysof', $nullsem->{keysof}, { null => 0 },
    sub { $S->{keysof}->($_[0]) });
}


# ===========================================================================
# walk
# ===========================================================================

my $walk_spec = $struct_spec->{walk};

grun('walk.basic', $walk_spec->{basic}, sub {
  my $walkpath = sub {
    my ($_key, $val, $_parent, $path) = @_;
    return $val if ref $val || !defined $val;
    return $val if !Voxgig::Struct::_is_string_sv($val);
    return $val . '~' . CORE::join('.', @$path);
  };
  return $S->{walk}->($_[0], $walkpath);
});

grun('walk.copy', $walk_spec->{copy}, sub {
  my ($in) = @_;
  my $cur;
  my $walkcopy = sub {
    my ($key, $val, $_parent, $path) = @_;
    if (!defined $key) {
      $cur = [];
      $cur->[0] =
          Voxgig::Struct::ismap($val) ? Voxgig::Struct::jm()
        : Voxgig::Struct::islist($val) ? []
        : $val;
      return $val;
    }

    my $v = $val;
    my $i = Voxgig::Struct::size($path);

    if (Voxgig::Struct::isnode($v)) {
      $v = $cur->[$i] = Voxgig::Struct::ismap($v) ? Voxgig::Struct::jm() : [];
    }

    Voxgig::Struct::setprop($cur->[$i - 1], $key, $v);

    return $val;
  };
  $S->{walk}->($in, $walkcopy);
  return $cur->[0];
});

grunflags('walk.depth', $walk_spec->{depth}, { null => 0 }, sub {
  my ($in) = @_;
  my ($top, $cur);
  my $copy = sub {
    my ($key, $val, $_parent, $_path) = @_;
    if (!defined $key || Voxgig::Struct::isnode($val)) {
      my $child = Voxgig::Struct::islist($val) ? [] : Voxgig::Struct::jm();
      if (!defined $key) { $top = $cur = $child }
      else {
        Voxgig::Struct::setprop($cur, $key, $child);
        $cur = $child;
      }
    }
    else {
      Voxgig::Struct::setprop($cur, $key, $val);
    }
    return $val;
  };
  $S->{walk}->($in->{src}, $copy, undef, $in->{maxdepth});
  return $top;
});

# walk.log is a single entry, not a set: the callback log for the after,
# before and both walks, in canonical's own rendering.
{
  my $td = UnivecOmni::tostruct(
    Voxgig::Omni::Util::clone($walk_spec->{log}));

  my $mklog = sub {
    my ($log) = @_;
    return sub {
      my ($key, $val, $parent, $path) = @_;
      push @$log, 'k=' . (defined $key ? Voxgig::Struct::stringify($key) : '')
        . ', v=' . Voxgig::Struct::stringify($val)
        . ', p=' . (defined $parent ? Voxgig::Struct::stringify($parent) : '')
        . ', t=' . Voxgig::Struct::pathify($path);
      return $val;
    };
  };

  my %lanes = (
    after => sub { my ($in, $log) = @_; $S->{walk}->($in, undef, $mklog->($log)) },
    before => sub { my ($in, $log) = @_; $S->{walk}->($in, $mklog->($log)) },
    both => sub { my ($in, $log) = @_; my $l = $mklog->($log); $S->{walk}->($in, $l, $l) },
  );

  for my $lane (sort keys %lanes) {
    my $log = [];
    $lanes{$lane}->(Voxgig::Struct::clone($td->{in}), $log);
    is_deeply($log, $td->{out}{$lane}, "walk.log $lane");
  }
}


# ===========================================================================
# merge
# ===========================================================================

my $merge_spec = $struct_spec->{merge};

# `merge.basic` is a single entry, not a set.
{
  my $basic = UnivecOmni::tostruct(
    Voxgig::Omni::Util::clone($merge_spec->{basic}));
  is(canon($S->{merge}->($basic->{in})), canon($basic->{out}), 'merge.basic');
}

grun('merge.cases', $merge_spec->{cases}, sub { $S->{merge}->($_[0]) });
grun('merge.array', $merge_spec->{array}, sub { $S->{merge}->($_[0]) });

# The entries assert the in-place result through `match.args`.
grun('merge.integrity', $merge_spec->{integrity}, sub { $S->{merge}->($_[0]) });

grun('merge.depth', $merge_spec->{depth},
  sub { $S->{merge}->($_[0]{val}, $_[0]{depth}) });


# ===========================================================================
# getpath
# ===========================================================================

my $getpath_spec = $struct_spec->{getpath};

grun('getpath.basic', $getpath_spec->{basic},
  sub { $S->{getpath}->($_[0]{store}, $_[0]{path}) });

grun('getpath.relative', $getpath_spec->{relative}, sub {
  my ($in) = @_;
  my $dpath = $in->{dpath};
  return $S->{getpath}->($in->{store}, $in->{path}, {
    dparent => $in->{dparent},
    (defined $dpath && !ref $dpath ? (dpath => [ split /\./, $dpath ]) : ()),
  });
});

grun('getpath.special', $getpath_spec->{special},
  sub { $S->{getpath}->($_[0]{store}, $_[0]{path}, $_[0]{inj}) });

grun('getpath.handler', $getpath_spec->{handler}, sub {
  my ($in) = @_;
  return $S->{getpath}->(
    Voxgig::Struct::jm('$TOP', $in->{store}, '$FOO', sub { 'foo' }),
    $in->{path},
    { handler => sub { my ($_inj, $val, $_cur, $_ref) = @_; return $val->() } },
  );
});


# ===========================================================================
# inject
# ===========================================================================

my $inject_spec = $struct_spec->{inject};

# `inject.basic` is a single entry, not a set.
{
  my $basic = UnivecOmni::tostruct(
    Voxgig::Omni::Util::clone($inject_spec->{basic}));
  is(canon($S->{inject}->($basic->{in}{val}, $basic->{in}{store})),
    canon($basic->{out}), 'inject.basic');
}

# The runner encodes "value is JSON null" as the NULLMARK string so it
# survives a JSON round trip; the resolver's null_modifier puts THIS
# port's null (JNULL) back as the structure is built.
grun('inject.string', $inject_spec->{string},
  sub { $S->{inject}->($_[0]{val}, $_[0]{store},
    { modify => \&UnivecOmni::null_modifier }) });

grun('inject.deep', $inject_spec->{deep},
  sub { $S->{inject}->($_[0]{val}, $_[0]{store}) });


# ===========================================================================
# transform
# ===========================================================================

my $transform_spec = $struct_spec->{transform};

# `transform.basic` is a single entry, not a set.
{
  my $basic = UnivecOmni::tostruct(
    Voxgig::Omni::Util::clone($transform_spec->{basic}));
  my $got = eval { $S->{transform}->($basic->{in}{data}, $basic->{in}{spec}) };
  is(canon($got), canon($basic->{out}), 'transform.basic');
}

for my $sec (qw(paths cmds each pack ref apply)) {
  grun("transform.$sec", $transform_spec->{$sec},
    sub { $S->{transform}->($_[0]{data}, $_[0]{spec}) });
}

grunflags('transform.format', $transform_spec->{format}, { null => 0 },
  sub { $S->{transform}->($_[0]{data}, $_[0]{spec}) });

grun('transform.modify', $transform_spec->{modify}, sub {
  my ($in) = @_;
  return $S->{transform}->($in->{data}, $in->{spec}, {
    modify => sub {
      my ($val, $key, $parent) = @_;
      return if !defined $key || !defined $parent || !ref $parent;
      return if ref $val || !defined $val;
      return if !Voxgig::Struct::_is_string_sv($val);
      Voxgig::Struct::setprop($parent, $key, '@' . $val);
      return;
    },
  });
});


# ===========================================================================
# validate
# ===========================================================================

my $validate_spec = $struct_spec->{validate};

grunflags('validate.basic', $validate_spec->{basic}, { null => 0 },
  sub { $S->{validate}->($_[0]{data}, $_[0]{spec}) });

for my $sec (qw(child one exact)) {
  grun("validate.$sec", $validate_spec->{$sec},
    sub { $S->{validate}->($_[0]{data}, $_[0]{spec}) });
}

grunflags('validate.invalid', $validate_spec->{invalid}, { null => 0 },
  sub { $S->{validate}->($_[0]{data}, $_[0]{spec}) });

grun('validate.special', $validate_spec->{special},
  sub { $S->{validate}->($_[0]{data}, $_[0]{spec}, $_[0]{inj}) });


# ===========================================================================
# select
# ===========================================================================

my $select_spec = $struct_spec->{select};

for my $sec (qw(basic operators edge alts)) {
  grun("select.$sec", $select_spec->{$sec},
    sub { $S->{select}->($_[0]{obj}, $_[0]{query}) });
}

done_testing();
