# Univec SDK test runner

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecTestRunner;

my $DIR = $__dir;

my %ENVLOCAL;
my $TEST_CONTROL;

sub load_env_local {
  my $env_file = "$DIR/../../.env.local";
  return unless -e $env_file;

  open my $fh, '<', $env_file or return;
  while (my $line = <$fh>) {
    $line =~ s/^\s+|\s+$//g;
    next if '' eq $line || $line =~ /^#/;
    my ($key, $val) = split /=/, $line, 2;
    next unless defined $key && defined $val;
    $key =~ s/^\s+|\s+$//g;
    $val =~ s/^\s+|\s+$//g;
    $ENVLOCAL{$key} = $val;
  }
  close $fh;
  return;
}

sub getenv {
  my ($key) = @_;
  return exists $ENVLOCAL{$key} ? $ENVLOCAL{$key} : $ENV{$key};
}

sub env_override {
  my ($m) = @_;
  my $live = getenv('PROJECTENV_TEST_LIVE');
  my $override = getenv('PROJECTENV_TEST_OVERRIDE');

  if ((defined $live && 'TRUE' eq $live)
    || (defined $override && 'TRUE' eq $override)) {
    for my $key (keys %$m) {
      my $envval = getenv($key);
      if (defined $envval && '' ne $envval) {
        $envval =~ s/^\s+|\s+$//g;
        if ($envval =~ /^\{/) {
          my $parsed = eval { Voxgig::Struct::parse_json($envval) };
          if (defined $parsed) {
            $m->{$key} = $parsed;
            next;
          }
        }
        $m->{$key} = $envval;
      }
    }
  }

  my $explain = getenv('PROJECTENV_TEST_EXPLAIN');
  $m->{'PROJECTENV_TEST_EXPLAIN'} = $explain if defined $explain && '' ne $explain;

  return $m;
}

sub entity_list_to_data {
  my ($list) = @_;
  my $out = [];
  for my $item (@{ $list || [] }) {
    if (Voxgig::Struct::ismap($item)) {
      push @$out, $item;
    }
    elsif (Scalar::Util::blessed($item) && $item->can('data_get')) {
      my $d = $item->data_get;
      push @$out, $d if Voxgig::Struct::ismap($d);
    }
  }
  return $out;
}

# Load sdk-test-control.json from this test dir; cache. Returns the
# empty-skip default if the file is missing or invalid.
sub load_test_control {
  return $TEST_CONTROL if defined $TEST_CONTROL;
  my $ctrl_path = "$DIR/sdk-test-control.json";
  $TEST_CONTROL = eval {
    open my $fh, '<:raw', $ctrl_path or die "no control file";
    local $/;
    my $text = <$fh>;
    close $fh;
    Voxgig::Struct::parse_json($text);
  };
  if (!defined $TEST_CONTROL) {
    $TEST_CONTROL = {
      'version' => 1,
      'test' => { 'skip' => {
        'live' => { 'direct' => [], 'entityOp' => [] },
        'unit' => { 'direct' => [], 'entityOp' => [] },
      }},
    };
  }
  return $TEST_CONTROL;
}

# Check sdk-test-control.json for a skip entry. Returns (skip, reason).
sub is_control_skipped {
  my ($kind, $name, $mode) = @_;
  my $ctrl = load_test_control();
  my $skip = UnivecHelpers::gpath($ctrl, "test.skip.$mode") || {};
  my $items = $skip->{$kind} || [];
  for my $item (@{ Voxgig::Struct::islist($items) ? $items : [] }) {
    next unless Voxgig::Struct::ismap($item);
    if ('direct' eq $kind && defined $item->{test} && $item->{test} eq $name) {
      return (1, $item->{reason});
    }
    if ('entityOp' eq $kind) {
      my $key = ($item->{entity} // '') . '.' . ($item->{op} // '');
      return (1, $item->{reason}) if $key eq $name;
    }
  }
  return (0, undef);
}

# Extra SDK options every LIVE client is constructed with, read from
# sdk-test-control.json `test.client.options`.
#
# The generated live client knows two things: the base URL (from the spec)
# and the credential (from the environment). Everything else about how a
# particular API wants to be talked to - which features to switch on, and
# with what settings - is a property of THAT API, known to the project and
# to nothing in the toolchain.
#
# Merged UNDER the generated fields, so the suite's own base/apikey/server
# values win: this ADDS to the live client, it does not redirect it.
#
# Reserved fields are stripped HERE rather than at each merge site: the
# generated hash only names a field when the model calls for one, so a
# "base" in this block would face no competing value and would silently
# redirect the whole suite - credential included - to another host.
my %LIVE_RESERVED = map { $_ => 1 }
  qw(base prefix suffix server apikey secret);

sub live_client_options {
  my $ctrl = load_test_control();
  my $opts = UnivecHelpers::gpath($ctrl, 'test.client.options');
  return {} unless Voxgig::Struct::ismap($opts);
  my %out;
  for my $k (keys %$opts) {
    $out{$k} = $opts->{$k} unless $LIVE_RESERVED{$k};
  }
  return \%out;
}

# Per-test live pacing delay (ms); default 500.
sub live_delay_ms {
  my $ctrl = load_test_control();
  my $v = UnivecHelpers::gpath($ctrl, 'test.live.delayMs');
  return $v if defined $v && !ref $v && $v =~ /^[0-9]+$/;
  return 500;
}

# A live check that did not pass, as main.kit.test.live.strict decides:
# strict fails the test, lenient skips it with the same reason. The caller
# leaves its block after either.
sub live_miss {
  my ($strict, $name, $reason) = @_;
  if ($strict) {
    Test::More::fail("$name: $reason");
  }
  else {
    Test::More->builder->skip("$name: $reason");
  }
  return;
}

# An account holding no record for the test to read skips either way.
sub live_empty {
  my ($name, $reason) = @_;
  Test::More->builder->skip("$name: $reason");
  return;
}

# A live list response's records: the body, or the first list an envelope
# holds.
sub live_list {
  my ($data) = @_;
  return $data if ref $data eq 'ARRAY';
  if (ref $data eq 'HASH') {
    for my $k (sort keys %$data) {
      return $data->{$k} if ref $data->{$k} eq 'ARRAY';
    }
  }
  return undef;
}

# A live response for a message: the SDK's error, or else its status and
# content type, never its body.
sub live_describe {
  my ($result) = @_;
  return 'no response' unless ref $result eq 'HASH';
  return '' . $result->{err} if defined $result->{err};
  my $ctype;
  for my $k (keys %{ $result->{headers} || {} }) {
    $ctype = $result->{headers}{$k} if lc($k) eq 'content-type';
  }
  my $out = 'HTTP ' . ($result->{status} // 'none');
  if (defined $ctype) {
    my ($media) = split /;/, $ctype;
    $media =~ s/^\s+|\s+$//g;
    $out .= " $media";
  }
  return $out;
}

# The record a create-less flow reads live: the first its list returns, put
# where the flow reads the fixture's existing records. False once the test
# is settled and its block ends.
sub live_existing {
  my ($setup, $strict, $label, $name, $list) = @_;
  my $found = eval { $list->() };
  if (my $err = $@) {
    live_miss($strict, $label, "Live list discovery failed: $err");
    return 0;
  }
  if (ref $found ne 'ARRAY') {
    live_miss($strict, $label, 'Live list discovery returned no list');
    return 0;
  }
  if (!@$found) {
    live_empty($label, "The account has no $name record to load");
    return 0;
  }
  my $first = $found->[0];
  my $record = (Scalar::Util::blessed($first) && $first->can('data_get'))
    ? $first->data_get : $first;
  $setup->{data}{existing}{$name} = { 'live01' => $record };
  return 1;
}

# In a lenient live run a step that dies skips, observing the live API.
sub live_observe {
  my ($err, $setup, $strict, $label) = @_;
  die $err if $strict || !$setup->{live};
  Test::More->builder->skip("$label: live run, main.kit.test.live.strict is false: $err");
  return;
}

1;
