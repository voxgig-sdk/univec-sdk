# Univec SDK utility: clean

use strict;
use warnings;

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{clean} = sub {
  my ($ctx, $val) = @_;
  return $val;
};

1;
