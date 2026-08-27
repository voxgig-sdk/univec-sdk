# Univec SDK clienttrack feature
#
# Client tracking. Establishes a stable per-client session id at
# construction and stamps identifying headers on every request: a
# "User-Agent" ("<clientName>/<clientVersion>"), an "X-Client-Id"
# (session), and a fresh per-request "X-Request-Id". This lets a server
# correlate all traffic from one SDK instance and each individual call.
# Header names, client name/version and the id generator ("idgen") are
# configurable; caller-provided User-Agent / X-Client-Id values are never
# clobbered.

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecClienttrackFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'clienttrack';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{session} = '';
  $self->{requests} = 0;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  $self->{requests} = 0;
  return;
}

sub PostConstruct {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  $self->{session} = defined $self->{options}{sessionId}
    ? $self->{options}{sessionId} : $self->_genid('session');
  $self->{client}{_clienttrack} = {
    'session' => $self->{session},
    'requests' => 0,
    'clientName' => $self->_client_name,
  };
  return;
}

sub PreRequest {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  my $spec = $ctx->{spec};
  return unless $spec;
  $spec->{headers} = {} unless defined $spec->{headers};
  if ('' eq $self->{session}) {
    $self->{session} = defined $self->{options}{sessionId}
      ? $self->{options}{sessionId} : $self->_genid('session');
  }

  my $h = $self->{options}{headers} || {};
  $self->{requests} += 1;
  my $request_id = $self->_genid('request');

  $self->_set($spec->{headers}, $h->{agent} || 'User-Agent', $self->_client_name);
  $self->_set($spec->{headers}, $h->{client} || 'X-Client-Id', $self->{session});
  $spec->{headers}{ $h->{request} || 'X-Request-Id' } = $request_id;

  my $track = $self->{client}{_clienttrack};
  if (!$track) {
    $track = {
      'session' => $self->{session},
      'requests' => 0,
      'clientName' => $self->_client_name,
    };
    $self->{client}{_clienttrack} = $track;
  }
  $track->{requests} = $self->{requests};
  $track->{lastRequestId} = $request_id;
  return;
}

# Do not clobber a caller-provided value (e.g. a custom User-Agent).
sub _set {
  my ($self, $headers, $name, $value) = @_;
  my $lower = lc $name;
  for my $k (keys %$headers) {
    return if lc("$k") eq $lower;
  }
  $headers->{$name} = $value;
  return;
}

sub _client_name {
  my ($self) = @_;
  my $name = defined $self->{options}{clientName}
    ? $self->{options}{clientName} : 'Univec-SDK';
  my $version = defined $self->{options}{clientVersion}
    ? $self->{options}{clientVersion} : '0.0.1';
  return "$name/$version";
}

sub _genid {
  my ($self, $kind) = @_;
  my $idgen = $self->{options}{idgen};
  return $idgen->($kind) if ref $idgen eq 'CODE';
  my $h = sub { sprintf('%x', int(rand(0x10000000))) };
  my $id = substr($kind, 0, 1) . '-' . $h->() . $h->() . $h->();
  return substr($id, 0, 20);
}

1;
