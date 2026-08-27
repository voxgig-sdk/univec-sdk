# Univec SDK netsim feature
#
# Network behaviour simulation. Wraps the active transport (the live HTTP
# fetcher or the test feature's in-memory mock) and injects realistic
# network conditions so offline unit tests can exercise slowness, transient
# failures, rate limiting and outages deterministically.
#
# Every injection mode is counter-driven (per client instance) so tests are
# reproducible without mocking timers. "failRate" adds optional
# pseudo-random failures via a seeded LCG for coverage-style testing.

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use POSIX ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecNetsimFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'netsim';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{calls} = 0;
  $self->{seed} = 1;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  my $seed = $self->{options}{seed};
  $seed = 0 unless defined $seed && !ref $seed
    && Scalar::Util::looks_like_number($seed);
  $self->{seed} = int($seed);
  $self->{seed} = 1 if 0 == $self->{seed};
  $self->{calls} = 0;

  return unless $self->{active};

  my $feature = $self;
  my $utility = $ctx->{utility};
  my $inner = $utility->{fetcher};

  $utility->{fetcher} = sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    return $feature->simulate($fctx, $fullurl, $fetchdef, $inner);
  };
  return;
}

sub simulate {
  my ($self, $ctx, $url, $fetchdef, $inner) = @_;
  my $opts = $self->{options};
  $self->{calls} += 1;
  my $call = $self->{calls};

  my $n = sub {
    my ($v) = @_;
    return 0 unless defined $v && !ref($v) && Scalar::Util::looks_like_number($v);
    return int($v);
  };

  # Record the simulated conditions for test/debug inspection.
  my $applied = {};

  # Total outage: every call fails at the transport level.
  if (UnivecHelpers::is_true($opts->{offline})) {
    $self->_sleep($self->_pick_latency);
    $applied->{offline} = Voxgig::Struct::JTRUE();
    $self->_track($ctx, $applied);
    return (undef, $ctx->make_error('netsim_offline',
      "Simulated network offline (URL was: \"$url\")"));
  }

  # Connection-level errors for the first N calls (e.g. ECONNRESET).
  if ($call <= $n->($opts->{errorTimes})) {
    $self->_sleep($self->_pick_latency);
    $applied->{error} = Voxgig::Struct::JTRUE();
    $self->_track($ctx, $applied);
    return (undef, $ctx->make_error('netsim_conn',
      "Simulated connection error (call $call)"));
  }

  # Rate-limit responses (HTTP 429 + Retry-After) for the first N calls.
  if ($call <= $n->($opts->{rateLimitTimes})) {
    $self->_sleep($self->_pick_latency);
    $applied->{rateLimited} = Voxgig::Struct::JTRUE();
    $self->_track($ctx, $applied);
    my $retry_after = defined $opts->{retryAfter} ? $opts->{retryAfter} : 0;
    return ($self->_respond(429, undef, {
      'statusText' => 'Too Many Requests',
      'headers' => { 'retry-after' => "$retry_after" },
    }), undef);
  }

  # Retryable failure status for the first N calls, or every Nth call.
  my $fail_status = defined $opts->{failStatus} ? $opts->{failStatus} : 503;
  my $fail_by_count = $call <= $n->($opts->{failTimes});
  my $fail_every = $n->($opts->{failEvery});
  my $fail_by_every = $fail_every > 0 && 0 == ($call % $fail_every);
  my $fail_rate = (defined $opts->{failRate} && !ref $opts->{failRate}
    && Scalar::Util::looks_like_number($opts->{failRate})) ? $opts->{failRate} : 0;
  my $fail_by_rate = $fail_rate > 0 && $self->_rand < $fail_rate;
  if ($fail_by_count || $fail_by_every || $fail_by_rate) {
    $self->_sleep($self->_pick_latency);
    $applied->{failStatus} = $fail_status;
    $self->_track($ctx, $applied);
    return ($self->_respond($fail_status, undef,
      { 'statusText' => 'Simulated Failure' }), undef);
  }

  # Otherwise: apply latency then delegate to the real transport.
  my $latency = $self->_pick_latency;
  $applied->{latency} = $latency;
  $self->_track($ctx, $applied);
  $self->_sleep($latency);
  return $inner->($ctx, $url, $fetchdef);
}

# Latency in ms: a fixed number, or a uniform sample from {min,max}.
sub _pick_latency {
  my ($self) = @_;
  my $l = $self->{options}{latency};
  return 0 unless defined $l;
  if (!ref($l) && Scalar::Util::looks_like_number($l)) {
    return $l < 0 ? 0 : $l;
  }
  return 0 unless Voxgig::Struct::ismap($l);
  my $min = defined $l->{min} ? int($l->{min}) : 0;
  my $max = defined $l->{max} ? int($l->{max}) : $min;
  return $min if $max <= $min;
  return $min + POSIX::floor($self->_rand * ($max - $min));
}

sub _sleep {
  my ($self, $ms) = @_;
  return if !defined $ms || $ms <= 0;
  my $s = $self->{options}{sleep};
  if (ref $s eq 'CODE') {
    $s->($ms);
  }
  else {
    UnivecHelpers::sleep_ms($ms);
  }
  return;
}

# Deterministic 0..1 pseudo-random via a linear congruential generator.
sub _rand {
  my ($self) = @_;
  $self->{seed} = ($self->{seed} * 1103515245 + 12345) & 0x7fffffff;
  return $self->{seed} / 0x7fffffff;
}

sub _track {
  my ($self, $ctx, $applied) = @_;
  my $track = $self->{client}{_netsim};
  if (!$track) {
    $track = { 'calls' => 0, 'applied' => [] };
    $self->{client}{_netsim} = $track;
  }
  $track->{calls} += 1;
  push @{ $track->{applied} }, $applied;
  if ($ctx->{ctrl} && $ctx->{ctrl}{explain}) {
    $ctx->{ctrl}{explain}{netsim} = $track;
  }
  return;
}

# Build a transport-shaped response (matching the test feature's mock)
# that the result pipeline understands.
sub _respond {
  my ($self, $status, $data, $extra) = @_;
  my $out = {
    'status' => $status,
    'statusText' => 'OK',
    'json' => sub { $data },
    'body' => 'not-used',
    'headers' => {},
  };
  if (Voxgig::Struct::ismap($extra)) {
    for my $k (keys %$extra) {
      my $v = $extra->{$k};
      if ('headers' eq $k && Voxgig::Struct::ismap($v)) {
        my $headers = {};
        $headers->{lc "$_"} = $v->{$_} for keys %$v;
        $out->{headers} = $headers;
      }
      else {
        $out->{$k} = $v;
      }
    }
  }
  return $out;
}

1;
