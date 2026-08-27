# Univec SDK log feature

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecLogFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'log';
  $self->{active} = 1;
  $self->{client} = undef;
  $self->{options} = undef;
  $self->{logger} = undef;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = $options;
  $self->{active} = UnivecHelpers::is_true($options->{active});

  if ($self->{active}) {
    if ($options->{logger}) {
      $self->{logger} = $options->{logger};
    }
    else {
      $self->{logger} = sub { print {*STDERR} $_[0], "\n" };
    }
  }
  return;
}

sub _loghook {
  my ($self, $hook, $ctx, $level) = @_;
  return unless $self->{logger};
  $level = 'info' unless defined $level;
  my $opname = $ctx->{op} ? $ctx->{op}{name} : '';
  my $msg = "hook=$hook op=$opname";
  my $line = '[' . uc($level) . "] $msg";
  my $logger = $self->{logger};
  if (ref $logger eq 'CODE') {
    $logger->($line);
  }
  elsif (ref(\$logger) eq 'GLOB' || ref $logger eq 'GLOB') {
    print {$logger} $line, "\n";
  }
  return;
}

sub PostConstruct { my ($s, $c) = @_; $s->_loghook('PostConstruct', $c) }
sub PostConstructEntity { my ($s, $c) = @_; $s->_loghook('PostConstructEntity', $c) }
sub SetData { my ($s, $c) = @_; $s->_loghook('SetData', $c) }
sub GetData { my ($s, $c) = @_; $s->_loghook('GetData', $c) }
sub SetMatch { my ($s, $c) = @_; $s->_loghook('SetMatch', $c) }
sub GetMatch { my ($s, $c) = @_; $s->_loghook('GetMatch', $c) }
sub PrePoint { my ($s, $c) = @_; $s->_loghook('PrePoint', $c) }
sub PreSpec { my ($s, $c) = @_; $s->_loghook('PreSpec', $c) }
sub PreRequest { my ($s, $c) = @_; $s->_loghook('PreRequest', $c) }
sub PreResponse { my ($s, $c) = @_; $s->_loghook('PreResponse', $c) }
sub PreResult { my ($s, $c) = @_; $s->_loghook('PreResult', $c) }

1;
