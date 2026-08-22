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

# Per-test live pacing delay (ms); default 500.
sub live_delay_ms {
  my $ctrl = load_test_control();
  my $v = UnivecHelpers::gpath($ctrl, 'test.live.delayMs');
  return $v if defined $v && !ref $v && $v =~ /^[0-9]+$/;
  return 500;
}

1;
