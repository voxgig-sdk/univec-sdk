# Univec SDK cache feature
#
# Response caching for safe (read) requests. Wraps the active transport and
# serves a fresh cached snapshot instead of hitting the network when the
# same method+URL was fetched within "ttl" ms (default 5000). Only
# successful (2xx) responses to cacheable methods (default: GET) are
# stored, keyed by method+URL. The cache is bounded ("max" entries, default
# 256, oldest evicted first) and every hit/miss/bypass is counted for
# inspection. Replayed responses expose a re-readable "json" body.

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

package UnivecCacheFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'cache';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{store} = {};
  # Perl hashes are unordered: keep an explicit insertion-order list so
  # eviction can drop the oldest entry first.
  $self->{order} = [];
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});

  return unless $self->{active};

  $self->{store} = {};
  $self->{order} = [];

  my $feature = $self;
  my $utility = $ctx->{utility};
  my $inner = $utility->{fetcher};

  $utility->{fetcher} = sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    return $feature->through($fctx, $fullurl, $fetchdef, $inner);
  };
  return;
}

sub through {
  my ($self, $ctx, $url, $fetchdef, $inner) = @_;
  my $method = Voxgig::Struct::ismap($fetchdef) && defined $fetchdef->{method}
    ? uc("$fetchdef->{method}") : 'GET';
  my $methods = $self->{options}{methods} || ['GET'];

  return $inner->($ctx, $url, $fetchdef)
    unless grep { uc("$_") eq $method } @$methods;

  my $key = "$method $url";
  my $now = $self->_now;
  my $hit = $self->{store}{$key};

  if (defined $hit && $hit->{expiry} > $now) {
    $self->_track('hit');
    return ($self->_replay($hit->{snapshot}), undef);
  }

  my ($res, $err) = $inner->($ctx, $url, $fetchdef);

  if (!defined $err && $self->_cacheable($res)) {
    my $snapshot = $self->_snapshot($res);
    my $ttl = defined $self->{options}{ttl} ? $self->{options}{ttl} : 5000;
    $self->_evict;
    if (!exists $self->{store}{$key}) {
      push @{ $self->{order} }, $key;
    }
    $self->{store}{$key} = { 'expiry' => $now + $ttl, 'snapshot' => $snapshot };
    $self->_track('miss');
    return ($self->_replay($snapshot), undef);
  }

  $self->_track('bypass');
  return ($res, $err);
}

sub _cacheable {
  my ($self, $res) = @_;
  return 0 unless Voxgig::Struct::ismap($res);
  my $status = $res->{status};
  return 0 unless defined $status && !ref($status)
    && Scalar::Util::looks_like_number($status);
  return ($status >= 200 && $status < 300) ? 1 : 0;
}

sub _snapshot {
  my ($self, $res) = @_;
  my $data;
  my $jf = $res->{json};
  if (ref $jf eq 'CODE') {
    $data = eval { $jf->() };
  }
  my $headers = Voxgig::Struct::ismap($res->{headers}) ? { %{ $res->{headers} } } : {};
  return {
    'status' => $res->{status},
    'statusText' => $res->{statusText},
    'data' => $data,
    'headers' => $headers,
  };
}

sub _replay {
  my ($self, $snapshot) = @_;
  my $data = $snapshot->{data};
  return {
    'status' => $snapshot->{status},
    'statusText' => $snapshot->{statusText},
    'body' => 'not-used',
    'json' => sub { $data },
    'headers' => Voxgig::Struct::ismap($snapshot->{headers}) ? { %{ $snapshot->{headers} } } : {},
  };
}

sub _evict {
  my ($self) = @_;
  my $max = defined $self->{options}{max} ? $self->{options}{max} : 256;
  while (scalar(keys %{ $self->{store} }) >= $max) {
    my $oldest = shift @{ $self->{order} };
    last unless defined $oldest;
    delete $self->{store}{$oldest};
  }
  return;
}

sub _now {
  my ($self) = @_;
  my $now = $self->{options}{now};
  return $now->() if ref $now eq 'CODE';
  return UnivecHelpers::now_ms();
}

sub _track {
  my ($self, $kind) = @_;
  my $track = $self->{client}{_cache};
  if (!$track) {
    $track = { 'hit' => 0, 'miss' => 0, 'bypass' => 0 };
    $self->{client}{_cache} = $track;
  }
  $track->{$kind} += 1;
  return;
}

1;
