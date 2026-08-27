#!perl
# Univec SDK feature corpus test
#
# Feature behaviour, driven by the SHARED corpus.
#
# The same route t/primary_utility.t takes for the utilities: language-neutral
# cases in .sdk/test/test.json, executed against THIS generated SDK. The
# feature is the ordinary package, built by the generated config, installed by
# the generated constructor, and driven by a real entity operation. Not a
# miniature of the pipeline, which can only be as right as the miniature.
#
# Everything in a case is data. The one piece perl writes for itself is
# turning scripted responses into a fetcher, through the documented
# `utility.fetcher` override.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd ();
use Scalar::Util ();

use UnivecSDK;

my $TEST_JSON = Cwd::abs_path("$FindBin::Bin/../../.sdk/test/test.json");

unless (defined $TEST_JSON && -e $TEST_JSON) {
  plan skip_all => 'test.json corpus not found';
}

# Features with a corpus section are read from the corpus itself (see the
# loop below), so a project-authored section - a custom feature added under
# .sdk/test/feature/ - runs without editing this file. An SDK generated
# without a listed feature still skips, not fails.

# The standard operation names, in the order the runner prefers them.
my @FEATURE_CORPUS_OPS = qw(load list create update remove);

my $CORPUS = do {
  open my $fh, '<', $TEST_JSON or die "cannot read $TEST_JSON: $!";
  local $/;
  my $raw = <$fh>;
  close $fh;
  Voxgig::Struct::parse_json($raw);
};

# A corpus with no `feature` section is a SKIP, not a failure. Each
# project carries its OWN materialised copy of .sdk/test/test.json, so a
# project scaffolded before the section existed legitimately has no cases
# to run - and a hard assertion here turned that into a red suite in every
# SDK on the fleet, for a corpus the project had simply not re-pulled yet.
# The strict check belongs where the corpus is CONTROLLED: sdkgen's own
# end-to-end lane supplies one and requires the cases to actually run.
unless (defined $CORPUS->{feature}) {
  plan skip_all => "this project's test.json has no `feature` section - "
    . 'recompile the corpus (create-sdkgen .sdk/test/feature/) to run these cases';
}
ok(defined $CORPUS->{feature}, 'the corpus carries a feature section');


# A scripted transport built from a case's `res` list. Responses are consumed
# in order and the last one repeats, so a case that does not care how many
# attempts happen need only declare one.
#
# Returns the shape the real fetcher returns: a (response, err) PAIR, with the
# parsed body behind a `json` coderef and `body` as the raw string. A script
# that only set `body` would look like an empty result, which reads as a
# feature defect rather than a mis-shaped script.
sub scripted_fetcher {
  my ($res) = @_;
  my $n = -1;
  return sub {
    my ($ctx, $fullurl, $fetchdef) = @_;
    $n++;
    my $spec = {};
    if (ref $res eq 'ARRAY' && @$res) {
      my $i = $n >= scalar(@$res) ? scalar(@$res) - 1 : $n;
      $spec = $res->[$i] || {};
    }

    if (($spec->{throw} || 0) eq '1' || (defined $spec->{throw} && $spec->{throw})) {
      return (undef, 'scripted transport failure');
    }

    my $status = defined $spec->{status} ? int($spec->{status}) : 200;
    my $body = defined $spec->{body} ? $spec->{body} : {};

    return ({
      'status'     => $status,
      'statusText' => ($status < 400 ? 'OK' : 'ERR'),
      'headers'    => { %{ $spec->{headers} || {} } },
      'json'       => sub { $body },
      'body'       => Voxgig::Struct::stringify($body),
    }, undef);
  };
}


# Build a client the way a caller would.
#
# The plain constructor, not the test-mode one: the `test` feature is
# transport: 'base' and REPLACES the transport, so a client in test mode
# would shadow the script.
sub build_client {
  my ($kase) = @_;
  my $opts = { 'utility' => { 'fetcher' => scripted_fetcher($kase->{res}) } };
  $opts->{feature} = $kase->{feature} if defined $kase->{feature};
  return UnivecSDK->new($opts);
}


# Every operation this SDK declares, in a stable order.
#
# The corpus cannot name an entity - it is shared by SDKs with none in common
# - so the runner finds them here. An entity accessor is a capitalised client
# method whose result answers get_name.
sub candidates {
  my ($client) = @_;
  my %found;

  my $pkg = ref $client;
  no strict 'refs';
  for my $sym (sort keys %{"${pkg}::"}) {
    next unless $sym =~ /^[A-Z]/;
    next unless defined &{"${pkg}::${sym}"};
    my $ent = eval { $client->$sym() };
    next unless defined $ent && Scalar::Util::blessed($ent);
    next unless $ent->can('get_name');
    my $entname = eval { $ent->get_name };
    next unless defined $entname && length $entname;
    $found{$entname} = [$sym, $ent];
  }
  use strict 'refs';

  my @out;
  for my $entname (sort keys %found) {
    my ($accessor, $ent) = @{ $found{$entname} };
    for my $opname (@FEATURE_CORPUS_OPS) {
      next unless $ent->can($opname);
      push @out, {
        key      => "$entname.$opname",
        accessor => $accessor,
        op       => $opname,
      };
    }
  }

  # SAFE OPS FIRST - see the ts harness for the reasoning: the cache stores
  # only successful GETs, so an SDK whose first usable op is a `create`
  # (POST) can never satisfy "a hit served from cache costs nothing".
  my %safe = (list => 0, load => 1);
  return sort {
    ($safe{ $a->{op} } // 2) <=> ($safe{ $b->{op} } // 2)
      || $a->{key} cmp $b->{key}
  } @out;
}


sub invoke {
  my ($client, $op, $ctrl) = @_;
  my $acc = $op->{accessor};
  my $fn  = $op->{op};
  my $ent = $client->$acc();
  return $ent->$fn({}, $ctrl);
}


# Pick operations by DRIVING them: an op is usable when it completes against a
# plain 200 with no feature active. Declared operations are not all callable
# with no arguments, and a case failing for that reason would read as a
# feature defect.
sub usable_ops {
  my ($want) = @_;
  my @picked;
  for my $cand (candidates(build_client({}))) {
    my $ok = eval { invoke(build_client({}), $cand, {}); 1 };
    next unless $ok;
    push @picked, $cand;
    last if scalar(@picked) >= $want;
  }
  return @picked;
}


# Replace #OPn throughout a case, keys included.
sub resolve {
  my ($node, $tokens) = @_;
  if (ref $node eq 'ARRAY') {
    return [ map { resolve($_, $tokens) } @$node ];
  }
  if (ref $node eq 'HASH') {
    my %out;
    for my $k (keys %$node) {
      $out{ resolve($k, $tokens) } = resolve($node->{$k}, $tokens);
    }
    return \%out;
  }
  if (!ref $node && defined $node) {
    my $out = $node;
    for my $tok (keys %$tokens) {
      my $q = quotemeta $tok;
      $out =~ s/$q/$tokens->{$tok}/g;
    }
    return $out;
  }
  return $node;
}


# The highest #OPn a case mentions.
sub tokens_used {
  my ($kase) = @_;
  my $json = Voxgig::Struct::stringify($kase);
  my $max = 0;
  while ($json =~ /#OP(\d+)/g) {
    $max = $1 if $1 > $max;
  }
  return $max;
}


sub member {
  my ($actual, $key) = @_;
  return (undef, 0) unless defined $actual;
  if (ref $actual eq 'HASH' || Scalar::Util::blessed($actual)) {
    return ($actual->{$key}, 1) if exists $actual->{$key};
  }
  return (undef, 0);
}


# Assert that `actual` contains `expect`, recursively. Cases assert only the
# fields they are about, so a full deep comparison would force every case to
# restate the whole record.
sub subset {
  my ($actual, $expect, $path) = @_;

  if (ref $expect eq 'HASH') {
    for my $k (sort keys %$expect) {
      my ($got, $found) = member($actual, $k);
      ok($found, "$path.$k exists") or next;
      subset($got, $expect->{$k}, "$path.$k");
    }
    return;
  }

  # JSON true/false parse to a blessed Voxgig::Struct::Bool, and perl's own
  # booleans are a bare 1 or ''. Compare truth, not spelling: stringified,
  # those two are 'true' and '1' and would never match.
  if (Voxgig::Struct::is_jbool($expect)) {
    is(($actual ? 1 : 0), ($expect ? 1 : 0), "$path is $expect");
    return;
  }

  if (!ref $expect && defined $expect && Scalar::Util::looks_like_number($expect)) {
    ok(!ref $actual && defined $actual && Scalar::Util::looks_like_number($actual),
      "$path is a number") or return;
    # Money is float arithmetic; compare with a tolerance far below any amount
    # a case states.
    ok(abs($actual - $expect) < 1e-9, "$path == $expect (got "
      . (defined $actual ? $actual : 'undef') . ')');
    return;
  }

  is($actual, $expect, $path);
}


sub record {
  my ($client, $name) = @_;
  return $client->{"_$name"};
}


my @ops = usable_ops(2);

# At least one operation, or every case would skip and this file would report
# green having run nothing.
ok(scalar(@ops) > 0,
  'this SDK has an operation the corpus can drive') or do {
  done_testing();
  exit 0;
};

for my $name (sort keys %{ $CORPUS->{feature} || {} }) {
  my $section = ($CORPUS->{feature} || {})->{$name};
  next unless defined $section;

  my $cases = (($section->{basic} || {})->{set}) || [];
  ok(scalar(@$cases) > 0,
    "corpus section feature.$name has cases (an emptied fixture must fail loudly)")
    or next;

  # Probed by ACTIVATING it: the feature defaults to inactive, so an idle
  # client never builds it and its absence says nothing.
  my $probe = build_client({ feature => [ { name => $name, active => 1 } ] });
  next unless defined record($probe, $name);

  my %by_key = map { $_->{key} => $_ } @ops;

  my $ran = 0;
  for my $raw (@$cases) {
    my $need = tokens_used($raw);
    next if $need > scalar(@ops);

    my %tokens;
    for my $i (0 .. $need - 1) {
      $tokens{ '#OP' . ($i + 1) } = $ops[$i]{key};
    }
    my $kase = resolve($raw, \%tokens);

    my $client = build_client($kase);
    my $label = $kase->{name} || '';

    for my $step (@{ $kase->{op} || [] }) {
      my $op = $by_key{ $step->{op} };
      ok(defined $op, "$label: operation $step->{op} is known") or next;
      my $ctrl = $step->{ctrl} || {};
      my $wanterr = $step->{err};

      my $ok = eval { invoke($client, $op, $ctrl); 1 };
      my $err = $@;

      if (!defined $wanterr) {
        ok($ok, "$label: $step->{op} succeeded")
          or diag("failed unexpectedly: $err");
        next;
      }

      ok(!$ok, "$label: $step->{op} failed as expected") or next;

      if (!ref $wanterr) {
        # The CODE, not the message: make_error prefixes and humanises the
        # text, so matching it would pass on any error mentioning the word.
        my $code = (Scalar::Util::blessed($err) && $err->can('code'))
          ? $err->code : undef;
        is($code, $wanterr, "$label: error code");
      }
    }

    subset(record($client, $name), $kase->{out}, "$label: _$name");
    $ran++;
  }

  ok($ran > 0, "at least one feature.$name case ran");
  # Say how many ran. A partial run is legitimate (an SDK with one operation
  # skips the cases needing two) but it should be visible rather than
  # inferred from a green tick.
  diag(sprintf('feature.%s: ran %d of %d case(s) against %d operation(s)',
    $name, $ran, scalar(@$cases), scalar(@ops)));
}

done_testing();
