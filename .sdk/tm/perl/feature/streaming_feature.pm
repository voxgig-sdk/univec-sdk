# Univec SDK streaming feature
#
# Streaming result support. For list-style operations it attaches a
# result.stream iterator (a coderef: each call yields the next item, undef
# when exhausted) so callers can consume items incrementally with
# while (defined(my $item = $result->{stream}->())) { ... } instead of
# materialising the whole array. The iterator reads the result's data
# lazily (on first call), so it reflects the parsed entities. A
# "chunkDelay" (ms) simulates paced/chunked delivery for offline tests via
# the injectable "sleep"; a "chunkSize" groups items into arrayref batches
# when set.

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecStreamingFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'streaming';
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

sub PreResult {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  return unless $self->_streamable($ctx);
  my $result = $ctx->{result};
  return unless $result;

  my $feature = $self;
  $result->{streaming} = 1;

  my $queue;
  $result->{stream} = sub {
    if (!defined $queue) {
      # Read lazily so downstream result processing is reflected.
      my @items = Voxgig::Struct::islist($result->{resdata})
        ? @{ $result->{resdata} } : ();
      my $chunk_size = $feature->{options}{chunkSize} || 0;
      if ($chunk_size > 0) {
        my @batches;
        while (@items) {
          push @batches, [splice @items, 0, $chunk_size];
        }
        $queue = \@batches;
      }
      else {
        $queue = \@items;
      }
    }
    return undef unless @$queue;
    my $chunk_delay = $feature->{options}{chunkDelay} || 0;
    $feature->_sleep($chunk_delay) if $chunk_delay > 0;
    return shift @$queue;
  };

  my $track = $self->{client}{_streaming};
  if (!$track) {
    $track = { 'opened' => 0 };
    $self->{client}{_streaming} = $track;
  }
  $track->{opened} += 1;
  return;
}

sub _streamable {
  my ($self, $ctx) = @_;
  my $ops = $self->{options}{ops} || ['list'];
  my $opname = $ctx->{op} ? $ctx->{op}{name} : undef;
  return (defined $opname && grep { "$_" eq $opname } @$ops) ? 1 : 0;
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

1;
