# Univec SDK retry feature
#
# Automatic retry of transient failures with exponential backoff and
# jitter. Wraps the active transport so a single operation call may make
# several HTTP attempts. A failure is retryable when the transport returns
# an error, or responds with a status in "statuses"
# (default: 408, 425, 429, 500, 502, 503, 504). An HTTP 429/503 with a
# "Retry-After" header overrides the computed backoff.

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

package UnivecRetryFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'retry';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});

  return unless $self->{active};

  my $feature = $self;
  my $utility = $ctx->{utility};
  my $inner = $utility->{fetcher};

  $utility->{fetcher} = sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    return $feature->with_retry($fctx, $fullurl, $fetchdef, $inner);
  };
  return;
}

sub with_retry {
  my ($self, $ctx, $url, $fetchdef, $inner) = @_;
  my $o = $self->{options};
  my $max = defined $o->{retries} ? int($o->{retries}) : 2;
  my $min_delay = defined $o->{minDelay} ? $o->{minDelay} : 50;
  my $max_delay = defined $o->{maxDelay} ? $o->{maxDelay} : 2000;
  my $factor = defined $o->{factor} ? $o->{factor} : 2;

  my $attempt = 0;
  while (1) {
    my ($res, $err) = $inner->($ctx, $url, $fetchdef);

    my $retryable = $self->_retryable($res, $err);
    if (!$retryable || $attempt >= $max) {
      # Out of attempts: return the last response/error tuple to preserve
      # pipeline semantics.
      return ($res, $err);
    }

    my $wait = $self->_backoff($res, $attempt, $min_delay, $max_delay, $factor);
    $self->_track($ctx, $attempt + 1, $res, $err, $wait);
    $self->_sleep($wait);
    $attempt++;
  }
}

sub _retryable {
  my ($self, $res, $err) = @_;
  return 1 if defined $err;
  return 1 if !defined $res;
  my $status = Voxgig::Struct::ismap($res) ? $res->{status} : undef;
  return 0 unless defined $status && !ref($status)
    && Scalar::Util::looks_like_number($status);
  my $statuses = $self->{options}{statuses} || [408, 425, 429, 500, 502, 503, 504];
  return (grep { $_ == int($status) } @$statuses) ? 1 : 0;
}

sub _backoff {
  my ($self, $res, $attempt, $min_delay, $max_delay, $factor) = @_;
  # Honour a server-provided Retry-After (seconds) when present.
  my $ra = $self->_retry_after($res);
  if (defined $ra) {
    return $max_delay < $ra ? $max_delay : $ra;
  }
  my $base = $min_delay * ($factor ** $attempt);
  my $jitter = UnivecHelpers::is_false($self->{options}{jitter})
    ? 0 : int(rand() * $min_delay);
  my $total = $base + $jitter;
  return $max_delay < $total ? $max_delay : $total;
}

sub _retry_after {
  my ($self, $res) = @_;
  return undef unless Voxgig::Struct::ismap($res);
  my $headers = $res->{headers};
  return undef unless Voxgig::Struct::ismap($headers);
  my $v;
  for my $k (keys %$headers) {
    $v = $headers->{$k} if lc("$k") eq 'retry-after';
  }
  return undef unless defined $v;
  return undef unless Scalar::Util::looks_like_number("$v");
  return int("$v" * 1000);
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
  my ($self, $ctx, $attempt, $res, $err, $wait) = @_;
  my $track = $self->{client}{_retry};
  if (!$track) {
    $track = { 'attempts' => 0, 'retries' => [] };
    $self->{client}{_retry} = $track;
  }
  $track->{attempts} += 1;
  push @{ $track->{retries} }, {
    'attempt' => $attempt,
    'status' => (Voxgig::Struct::ismap($res) ? $res->{status} : undef),
    'error' => (defined $err ? "$err" : undef),
    'wait' => $wait,
  };
  return;
}

1;
