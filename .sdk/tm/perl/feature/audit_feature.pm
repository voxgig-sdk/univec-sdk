# Univec SDK audit feature
#
# Audit trail. Emits a structured record for every operation - who (actor),
# what (entity + op), the outcome, and a correlation id - suitable for
# compliance logging. Records accumulate on the client (bounded by "max",
# default 1000) and, when a "sink" callback is supplied, are also pushed to
# it (e.g. to forward to a SIEM). The actor is taken from a per-call
# ctrl actor, then options "actor", then "anonymous". Timestamps use the
# injectable "now" clock (ms) so tests stay deterministic. One record per
# operation (emit-once).

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

package UnivecAuditFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'audit';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{seq} = 0;
  $self->{seen} = {};
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  $self->{seq} = 0;
  $self->{seen} = {};

  return unless $self->{active};

  if (!$self->{client}{_audit}) {
    $self->{client}{_audit} = { 'records' => [] };
  }
  return;
}

sub PreDone {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  # Outcome reflects the actual result: a non-2xx reaches PreDone before
  # the pipeline dies.
  my $ok = ($ctx->{result} && $ctx->{result}{ok} && !defined $ctx->{result}{err}) ? 1 : 0;
  $self->_emit($ctx, $ok ? 'ok' : 'error');
  return;
}

sub PreUnexpected {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  $self->_emit($ctx, 'error');
  return;
}

sub _emit {
  my ($self, $ctx, $outcome) = @_;
  # One record per operation (PreDone + a following PreUnexpected on a
  # non-2xx must not double-log).
  my $addr = Scalar::Util::refaddr($ctx);
  return if exists $self->{seen}{$addr};
  $self->{seen}{$addr} = 1;
  $self->{seq} += 1;

  my $record = {
    'seq' => $self->{seq},
    'ts' => $self->_now,
    'actor' => $self->_actor($ctx),
    'entity' => ($ctx->{op} ? $ctx->{op}{entity} : '_'),
    'op' => ($ctx->{op} ? $ctx->{op}{name} : '_'),
    'outcome' => $outcome,
    'status' => ($ctx->{result} ? $ctx->{result}{status} : undef),
    'correlationId' => $ctx->{id},
  };

  my $track = $self->{client}{_audit};
  if (!$track) {
    $track = { 'records' => [] };
    $self->{client}{_audit} = $track;
  }
  my $recs = $track->{records};
  push @$recs, $record;
  my $max = defined $self->{options}{max} ? $self->{options}{max} : 1000;
  shift @$recs while @$recs > $max;

  my $sink = $self->{options}{sink};
  if (ref $sink eq 'CODE') {
    eval { $sink->($record) };
  }
  return;
}

sub _actor {
  my ($self, $ctx) = @_;
  if ($ctx->{ctrl} && defined $ctx->{ctrl}{actor}) {
    return $ctx->{ctrl}{actor};
  }
  return defined $self->{options}{actor} ? $self->{options}{actor} : 'anonymous';
}

sub _now {
  my ($self) = @_;
  my $now = $self->{options}{now};
  return $now->() if ref $now eq 'CODE';
  return UnivecHelpers::now_ms();
}

1;
