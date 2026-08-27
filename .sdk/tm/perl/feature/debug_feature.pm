# Univec SDK debug feature
#
# Request/response capture for debugging. Records a bounded ring buffer of
# per-operation traces - method, URL, redacted headers, response status and
# timing. Sensitive header values (matching "redact", default
# authorization/cookie/api-key style names) are masked. An optional
# "on_entry" callback receives each finished entry (e.g. to stream to a
# console). "max" caps the buffer (default 100). The clock is injectable
# ("now", ms) for deterministic tests.

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

package UnivecDebugFeature;

our @ISA = ('UnivecBaseFeature');

my @REDACT_DEFAULT = (
  'authorization', 'cookie', 'set-cookie', 'api-key', 'apikey',
  'x-api-key', 'idempotency-key',
);

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'debug';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{entries} = {};
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  $self->{entries} = {};

  return unless $self->{active};

  if (!$self->{client}{_debug}) {
    $self->{client}{_debug} = { 'entries' => [] };
  }
  return;
}

sub PreRequest {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  my $spec = $ctx->{spec};
  my ($url, $method, $headers);
  if ($spec) {
    $url = (defined $spec->{url} && '' ne "$spec->{url}") ? $spec->{url} : $spec->{path};
    $method = $spec->{method};
    $headers = $spec->{headers};
  }
  my $entry = {
    'op' => ($ctx->{op} ? $ctx->{op}{entity} : '_') . '.'
      . ($ctx->{op} ? $ctx->{op}{name} : '_'),
    'method' => $method,
    'url' => $url,
    'headers' => $self->_redact($headers),
    'start' => $self->_now,
    'status' => undef,
    'ok' => undef,
    'durationMs' => undef,
    'error' => undef,
  };
  $self->{entries}{Scalar::Util::refaddr($ctx)} = $entry;
  return;
}

sub PreResponse {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  my $entry = $self->{entries}{Scalar::Util::refaddr($ctx)};
  return unless $entry;
  my $response = $ctx->{response};
  if ($response) {
    $entry->{status} = $response->{status};
    if ((!defined $entry->{url} || '' eq "$entry->{url}") && $ctx->{spec}) {
      $entry->{url} = $ctx->{spec}{url};
    }
  }
  return;
}

sub PreDone {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  $self->_finish($ctx, 1);
  return;
}

sub PreUnexpected {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  my $entry = $self->{entries}{Scalar::Util::refaddr($ctx)};
  if ($entry && $ctx->{ctrl} && $ctx->{ctrl}{err}) {
    $entry->{error} = '' . $ctx->{ctrl}{err};
  }
  $self->_finish($ctx, 0);
  return;
}

sub _finish {
  my ($self, $ctx, $ok) = @_;
  my $entry = delete $self->{entries}{Scalar::Util::refaddr($ctx)};
  return unless $entry;
  $entry->{ok} = ($ok && (!$ctx->{result} || $ctx->{result}{ok}))
    ? Voxgig::Struct::JTRUE() : Voxgig::Struct::JFALSE();
  my $dur = $self->_now - $entry->{start};
  $entry->{durationMs} = $dur > 0 ? $dur : 0;
  if (!defined $entry->{status} && $ctx->{result}) {
    $entry->{status} = $ctx->{result}{status};
  }

  my $track = $self->{client}{_debug};
  if (!$track) {
    $track = { 'entries' => [] };
    $self->{client}{_debug} = $track;
  }
  my $buf = $track->{entries};
  push @$buf, $entry;
  my $max = defined $self->{options}{max} ? $self->{options}{max} : 100;
  shift @$buf while @$buf > $max;

  my $on_entry = $self->{options}{on_entry};
  if (ref $on_entry eq 'CODE') {
    eval { $on_entry->($entry) };
  }
  return;
}

sub _redact {
  my ($self, $headers) = @_;
  return {} unless defined $headers;
  my $patterns = $self->{options}{redact} || \@REDACT_DEFAULT;
  my $out = {};
  for my $k (keys %$headers) {
    $out->{$k} = (grep { "$_" eq lc("$k") } @$patterns)
      ? '<redacted>' : $headers->{$k};
  }
  return $out;
}

sub _now {
  my ($self) = @_;
  my $now = $self->{options}{now};
  return $now->() if ref $now eq 'CODE';
  return UnivecHelpers::now_ms();
}

1;
