# Univec SDK utility type

use strict;
use warnings;

package UnivecUtility;

# The utility object is a blessed hash whose members are the named pipeline
# utilities (fetcher, make_spec, ...), each a coderef called as
# $utility->{name}->(...). The registrar (set by utility/register.pm)
# populates a fresh instance.

our $REGISTRAR;

sub new {
  my ($class) = @_;
  my $self = bless { custom => {} }, $class;
  $REGISTRAR->($self) if $REGISTRAR;
  return $self;
}

sub copy {
  my ($class, $src) = @_;
  my $u = $class->new;
  for my $k (keys %$src) {
    $u->{$k} = $src->{$k};
  }
  $u->{custom} = { %{ $src->{custom} || {} } };
  return $u;
}

1;
