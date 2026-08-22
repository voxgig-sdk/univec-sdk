# Univec SDK control

use strict;
use warnings;

package UnivecControl;

sub new {
  my ($class, $opts) = @_;
  $opts = {} unless defined $opts && ref($opts) eq 'HASH';
  return bless {
    throw_err => $opts->{throw_err},
    err       => undef,
    explain   => $opts->{explain},
    # Per-call audit actor (used by the audit feature).
    actor     => $opts->{actor},
    # Per-call paging override (used by the paging feature).
    paging    => $opts->{paging},
  }, $class;
}

1;
