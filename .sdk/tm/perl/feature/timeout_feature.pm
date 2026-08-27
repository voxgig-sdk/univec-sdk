# Univec SDK timeout feature
#
# Per-request timeout. Wraps the active transport with a deadline of "ms"
# milliseconds (default 30000; <= 0 disables). The transport is synchronous
# (HTTP::Tiny), so a hanging request is interrupted with a SIGALRM timer
# (Time::HiRes::ualarm); when an injectable "now" clock is supplied the
# elapsed wall-clock time is checked instead, so tests can assert the
# deadline deterministically. Expiry yields an error with code "timeout".

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Time::HiRes ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecTimeoutFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'timeout';
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
    return $feature->with_timeout($fctx, $fullurl, $fetchdef, $inner);
  };
  return;
}

sub with_timeout {
  my ($self, $ctx, $url, $fetchdef, $inner) = @_;
  my $ms = defined $self->{options}{ms} ? $self->{options}{ms} : 30000;
  return $inner->($ctx, $url, $fetchdef) if $ms <= 0;

  my $now = $self->{options}{now};
  if (ref $now eq 'CODE') {
    # Deterministic path: measure the (virtual) clock around the call.
    my $start = $now->();
    my ($res, $err) = $inner->($ctx, $url, $fetchdef);
    if ($now->() - $start > $ms) {
      $self->_track($ctx, $ms);
      return (undef, $ctx->make_error('timeout', "Request exceeded timeout of ${ms}ms"));
    }
    return ($res, $err);
  }

  # Live path: interrupt a hanging synchronous transport.
  my ($res, $err);
  my $timed_out = 0;
  my $ok = do {
    local $SIG{ALRM} = sub { $timed_out = 1; die "UnivecTimeout\n" };
    eval {
      Time::HiRes::ualarm(int($ms * 1000));
      ($res, $err) = $inner->($ctx, $url, $fetchdef);
      Time::HiRes::ualarm(0);
      1;
    };
  };
  Time::HiRes::ualarm(0);
  if (!$ok) {
    my $e = $@;
    if ($timed_out) {
      $self->_track($ctx, $ms);
      return (undef, $ctx->make_error('timeout', "Request exceeded timeout of ${ms}ms"));
    }
    die $e;
  }
  return ($res, $err);
}

sub _track {
  my ($self, $ctx, $ms) = @_;
  my $track = $self->{client}{_timeout};
  if (!$track) {
    $track = { 'count' => 0, 'ms' => $ms };
    $self->{client}{_timeout} = $track;
  }
  $track->{count} += 1;
  return;
}

1;
