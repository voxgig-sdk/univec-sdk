# ProjectName SDK error

use strict;
use warnings;

package ProjectNameError;

use overload
  '""'     => sub { defined $_[0]->{msg} ? $_[0]->{msg} : '' },
  'bool'   => sub { 1 },
  fallback => 1;

sub new {
  my ($class, $code, $msg) = @_;
  return bless {
    code => (defined $code ? $code : ''),
    msg  => (defined $msg ? $msg : ''),
    sdk  => 'ProjectName',
  }, $class;
}

sub error {
  my ($self) = @_;
  return "$self->{sdk}: $self->{code}: $self->{msg}";
}

1;
