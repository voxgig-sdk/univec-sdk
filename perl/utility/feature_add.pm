# Univec SDK utility: feature_add

use strict;
use warnings;

package UnivecUtilities;

our %REGISTRY;

# Features can position themselves relative to an already-added feature
# via `_options` ("__before__" / "__after__" / "__replace__"), set by the
# caller on `extend` feature instances - mirrors the ts featureAdd. The
# first match wins; with no match the feature is appended.
$REGISTRY{feature_add} = sub {
  my ($ctx, $f) = @_;
  my $features = $ctx->{client}{features};

  my $fopts = $f->{_options} || {};
  my $before = $fopts->{__before__};
  my $after = $fopts->{__after__};
  my $replace = $fopts->{__replace__};

  if (defined $before || defined $after || defined $replace) {
    for my $i (0 .. $#$features) {
      my $ef = $features->[$i];
      my $name = (ref $ef && exists $ef->{name}) ? $ef->{name} : undef;
      next unless defined $name;
      if (defined $before && $before eq $name) {
        splice @$features, $i, 0, $f;
        return;
      }
      elsif (defined $after && $after eq $name) {
        splice @$features, $i + 1, 0, $f;
        return;
      }
      elsif (defined $replace && $replace eq $name) {
        $features->[$i] = $f;
        return;
      }
    }
  }

  push @$features, $f;
  return;
};

1;
