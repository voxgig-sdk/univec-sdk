# Univec SDK base feature

use strict;
use warnings;

package UnivecBaseFeature;

# Blessed-hash feature object. `_options` positions this feature when added
# via the client `extend` option: "__before__" / "__after__" / "__replace__"
# name an already-added feature (mirrors the ts feature `_options`).

sub new {
  my ($class) = @_;
  return bless {
    version  => '0.0.1',
    name     => 'base',
    active   => 1,
    _options => undef,
  }, $class;
}

sub get_version { $_[0]->{version} }
sub get_name    { $_[0]->{name} }
sub get_active  { $_[0]->{active} }

sub init { }
sub PostConstruct { }
sub PostConstructEntity { }
sub SetData { }
sub GetData { }
sub GetMatch { }
sub SetMatch { }
sub PrePoint { }
sub PreSpec { }
sub PreRequest { }
sub PreResponse { }
sub PreResult { }
sub PreDone { }
sub PreUnexpected { }

1;
