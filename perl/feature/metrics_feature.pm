# Univec SDK metrics feature
#
# Statistics capture. Records per-operation counters and latency for every
# call: totals plus a breakdown keyed by "<entity>.<op>". Timing starts at
# endpoint resolution (PrePoint) and stops when the call returns (PreDone)
# or fails (PreUnexpected) - exactly once per operation. The clock is
# injectable ("now", ms) for deterministic tests.

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

package UnivecMetricsFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'metrics';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{starts} = {};
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  $self->{starts} = {};

  return unless $self->{active};

  if (!$self->{client}{_metrics}) {
    $self->{client}{_metrics} = {
      'total' => { 'count' => 0, 'ok' => 0, 'err' => 0, 'totalMs' => 0, 'maxMs' => 0 },
      'ops' => {},
    };
  }
  return;
}

sub PrePoint {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  $self->{starts}{Scalar::Util::refaddr($ctx)} = $self->_now;
  return;
}

sub PreDone {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  # Classify by the actual result: a 4xx/5xx that flows through still
  # reaches PreDone before the pipeline dies.
  my $ok = ($ctx->{result} && $ctx->{result}{ok} && !defined $ctx->{result}{err}) ? 1 : 0;
  $self->_record($ctx, $ok);
  return;
}

sub PreUnexpected {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  $self->_record($ctx, 0);
  return;
}

sub _record {
  my ($self, $ctx, $ok) = @_;
  # Record once per operation. When a non-2xx result reaches PreDone the
  # pipeline then dies, firing PreUnexpected too; the missing start
  # marker makes the second call a no-op.
  my $addr = Scalar::Util::refaddr($ctx);
  return unless exists $self->{starts}{$addr};
  my $start = delete $self->{starts}{$addr};
  my $dur = defined $start ? $self->_now - $start : 0;
  $dur = 0 if $dur < 0;

  my $m = $self->{client}{_metrics};
  return unless $m;
  my $key = ($ctx->{op} ? $ctx->{op}{entity} : '_') . '.'
    . ($ctx->{op} ? $ctx->{op}{name} : '_');

  my $op = $m->{ops}{$key};
  if (!$op) {
    $op = { 'count' => 0, 'ok' => 0, 'err' => 0, 'totalMs' => 0, 'maxMs' => 0 };
    $m->{ops}{$key} = $op;
  }

  $self->_bump($m->{total}, $ok, $dur);
  $self->_bump($op, $ok, $dur);
  return;
}

sub _bump {
  my ($self, $bucket, $ok, $dur) = @_;
  $bucket->{count} += 1;
  $bucket->{ $ok ? 'ok' : 'err' } += 1;
  $bucket->{totalMs} += $dur;
  $bucket->{maxMs} = $dur if $dur > $bucket->{maxMs};
  return;
}

sub _now {
  my ($self) = @_;
  my $now = $self->{options}{now};
  return $now->() if ref $now eq 'CODE';
  return UnivecHelpers::now_ms();
}

1;
