# Univec SDK utility: feature_hook

use strict;
use warnings;

use Scalar::Util ();

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{feature_hook} = sub {
  my ($ctx, $name) = @_;
  return unless $ctx->{client};
  my $features = $ctx->{client}{features};
  return unless $features && ref $features eq 'ARRAY';
  for my $f (@$features) {
    if (Scalar::Util::blessed($f) && $f->can($name)) {
      $f->$name($ctx);
    }
  }
  return;
};

1;
