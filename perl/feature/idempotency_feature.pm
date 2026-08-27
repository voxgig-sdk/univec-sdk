# Univec SDK idempotency feature
#
# Idempotency keys for mutating operations. Adds an "Idempotency-Key"
# header (name configurable via "header") to unsafe requests so a server
# can de-duplicate retried writes. The key is set once, at PreRequest,
# before the request is built - so it is stable across transport-level
# retries of the same call. A caller-supplied header is never overwritten
# (case-insensitive). The key generator is injectable via "keygen".

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecIdempotencyFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'idempotency';
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
  return;
}

sub PreRequest {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  my $spec = $ctx->{spec};
  return unless $spec;

  return unless $self->_mutating($ctx);

  my $header = defined $self->{options}{header}
    ? $self->{options}{header} : 'Idempotency-Key';
  $spec->{headers} = {} unless defined $spec->{headers};

  # Respect a key the caller already provided.
  return if defined $self->_existing($spec->{headers}, $header);

  my $key = $self->_genkey;
  $spec->{headers}{$header} = $key;

  my $track = $self->{client}{_idempotency};
  if (!$track) {
    $track = { 'issued' => 0, 'last' => undef };
    $self->{client}{_idempotency} = $track;
  }
  $track->{issued} += 1;
  $track->{last} = $key;
  return;
}

sub _mutating {
  my ($self, $ctx) = @_;
  my $methods = $self->{options}{methods} || ['POST', 'PUT', 'PATCH', 'DELETE'];
  my $method = '';
  $method = uc("$ctx->{spec}{method}") if $ctx->{spec} && defined $ctx->{spec}{method};
  return 1 if '' ne $method && grep { uc("$_") eq $method } @$methods;
  my $opname = $ctx->{op} ? $ctx->{op}{name} : undef;
  my $ops = $self->{options}{ops} || ['create', 'update', 'remove'];
  return (defined $opname && grep { "$_" eq $opname } @$ops) ? 1 : 0;
}

sub _existing {
  my ($self, $headers, $header) = @_;
  my $lower = lc $header;
  for my $k (keys %$headers) {
    return $headers->{$k} if lc("$k") eq $lower;
  }
  return undef;
}

sub _genkey {
  my ($self) = @_;
  my $keygen = $self->{options}{keygen};
  return $keygen->() if ref $keygen eq 'CODE';
  my $h = sub { sprintf('%x', int(rand(0x10000000))) };
  my $key = $h->() . $h->() . $h->() . $h->();
  $key .= '0' x (24 - length $key) if length($key) < 24;
  return substr($key, 0, 24);
}

1;
