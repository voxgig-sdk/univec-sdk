# Univec SDK ratelimit feature
#
# Client-side rate limiting via a token bucket. Each request consumes a
# token; when the bucket is empty the request waits until the bucket
# refills at "rate" tokens per second (with capacity "burst", default:
# rate). This keeps the client under a server's published quota rather than
# discovering it via 429s. The clock ("now", ms) and the wait ("sleep") are
# injectable so the accounting can be tested deterministically.

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use POSIX ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecRatelimitFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'ratelimit';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{tokens} = 0;
  $self->{last} = 0;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});

  return unless $self->{active};

  my $burst = defined $self->{options}{burst}
    ? $self->{options}{burst}
    : (defined $self->{options}{rate} ? $self->{options}{rate} : 5);
  $self->{tokens} = $burst;
  $self->{last} = $self->_now;

  my $feature = $self;
  my $utility = $ctx->{utility};
  my $inner = $utility->{fetcher};

  $utility->{fetcher} = sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    $feature->acquire($fctx);
    return $inner->($fctx, $fullurl, $fetchdef);
  };
  return;
}

sub acquire {
  my ($self, $ctx) = @_;
  my $rate = defined $self->{options}{rate} ? $self->{options}{rate} : 5;
  my $burst = defined $self->{options}{burst} ? $self->{options}{burst} : $rate;

  # Refill according to elapsed time.
  my $now = $self->_now;
  my $elapsed = $now - $self->{last};
  $self->{last} = $now;
  my $refilled = $self->{tokens} + ($elapsed / 1000.0) * $rate;
  $self->{tokens} = $burst < $refilled ? $burst : $refilled;

  if ($self->{tokens} >= 1) {
    $self->{tokens} -= 1;
    return;
  }

  # Not enough tokens: wait for one to accrue, then consume it.
  my $needed = 1 - $self->{tokens};
  my $wait_ms = POSIX::ceil(($needed / (0 + $rate)) * 1000);
  $self->_track($ctx, $wait_ms);
  $self->_sleep($wait_ms);
  $self->{last} = $self->_now;
  $self->{tokens} = 0;
  return;
}

sub _now {
  my ($self) = @_;
  my $now = $self->{options}{now};
  return $now->() if ref $now eq 'CODE';
  return UnivecHelpers::now_ms();
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

sub _track {
  my ($self, $ctx, $wait_ms) = @_;
  my $track = $self->{client}{_ratelimit};
  if (!$track) {
    $track = { 'throttled' => 0, 'waitMs' => 0 };
    $self->{client}{_ratelimit} = $track;
  }
  $track->{throttled} += 1;
  $track->{waitMs} += $wait_ms;
  return;
}

1;
