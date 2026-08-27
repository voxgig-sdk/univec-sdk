# Univec SDK telemetry feature
#
# Distributed-tracing telemetry. Opens a span per operation (PrePoint),
# propagates trace context to the server as W3C "traceparent" plus
# "X-Trace-Id" / "X-Span-Id" headers (PreRequest), and closes the span on
# completion (PreDone) or failure (PreUnexpected) - exactly once. Finished
# spans are kept on the client; an "exporter" callback, when provided, is
# invoked with each finished span. Trace/span id generation ("idgen") and
# the clock ("now", ms) are injectable for deterministic tests.

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

package UnivecTelemetryFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'telemetry';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{spans} = {};
  $self->{seq} = 0;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  $self->{spans} = {};
  $self->{seq} = 0;

  return unless $self->{active};

  if (!$self->{client}{_telemetry}) {
    $self->{client}{_telemetry} = { 'spans' => [], 'active' => 0 };
  }
  return;
}

sub PrePoint {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  my $span = {
    'traceId' => $self->_id('trace'),
    'spanId' => $self->_id('span'),
    'name' => ($ctx->{op} ? $ctx->{op}{entity} : '_') . '.'
      . ($ctx->{op} ? $ctx->{op}{name} : '_'),
    'start' => $self->_now,
    'end' => undef,
    'durationMs' => undef,
    'ok' => undef,
  };
  $self->{spans}{Scalar::Util::refaddr($ctx)} = $span;
  my $t = $self->_telemetry;
  $t->{active} += 1 if $t;
  return;
}

sub PreRequest {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  my $span = $self->{spans}{Scalar::Util::refaddr($ctx)};
  my $spec = $ctx->{spec};
  return if !$span || !$spec;
  $spec->{headers} = {} unless defined $spec->{headers};
  my $h = $self->{options}{headers} || {};
  $spec->{headers}{ $h->{trace} || 'X-Trace-Id' } = $span->{traceId};
  $spec->{headers}{ $h->{span} || 'X-Span-Id' } = $span->{spanId};
  $spec->{headers}{ $h->{parent} || 'traceparent' } =
    "00-$span->{traceId}-$span->{spanId}-01";
  return;
}

sub PreDone {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  my $ok = ($ctx->{result} && $ctx->{result}{ok} && !defined $ctx->{result}{err}) ? 1 : 0;
  $self->_close($ctx, $ok);
  return;
}

sub PreUnexpected {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  $self->_close($ctx, 0);
  return;
}

sub _close {
  my ($self, $ctx, $ok) = @_;
  # Close once per operation; a PreDone followed by a pipeline die
  # (non-2xx) fires PreUnexpected too, which then finds no open span.
  my $span = delete $self->{spans}{Scalar::Util::refaddr($ctx)};
  return unless $span;
  $span->{end} = $self->_now;
  my $dur = $span->{end} - $span->{start};
  $span->{durationMs} = $dur > 0 ? $dur : 0;
  $span->{ok} = $ok ? Voxgig::Struct::JTRUE() : Voxgig::Struct::JFALSE();

  my $t = $self->_telemetry;
  if ($t) {
    $t->{active} -= 1;
    push @{ $t->{spans} }, $span;
  }

  my $exporter = $self->{options}{exporter};
  if (ref $exporter eq 'CODE') {
    eval { $exporter->($span) };
  }
  return;
}

sub _telemetry {
  my ($self) = @_;
  return $self->{client}{_telemetry};
}

sub _id {
  my ($self, $kind) = @_;
  my $idgen = $self->{options}{idgen};
  return $idgen->($kind) if ref $idgen eq 'CODE';
  # Deterministic-ish sequential id; unique within a client instance.
  $self->{seq} += 1;
  my $n = sprintf('%04x', $self->{seq});
  my $id = ('trace' eq $kind ? 't' : 's') . $n;
  $id .= '0' x (17 - length $id) if length($id) < 17;
  return $id;
}

sub _now {
  my ($self) = @_;
  my $now = $self->{options}{now};
  return $now->() if ref $now eq 'CODE';
  return UnivecHelpers::now_ms();
}

1;
