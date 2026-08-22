# Univec SDK utility: make_result

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{make_result} = sub {
  my ($ctx) = @_;
  return ($ctx->{out}{result}, undef) if $ctx->{out}{result};

  my $utility = $ctx->{utility};
  my $op = $ctx->{op};
  my $entity = $ctx->{entity};
  my $spec = $ctx->{spec};
  my $result = $ctx->{result};

  return (undef, $ctx->make_error('result_no_spec',
    'Expected context spec property to be defined.')) unless $spec;
  return (undef, $ctx->make_error('result_no_result',
    'Expected context result property to be defined.')) unless $result;

  $spec->{step} = 'result';
  $utility->{transform_response}->($ctx);

  if ('list' eq $op->{name}) {
    my $resdata = $result->{resdata};
    $result->{resdata} = [];
    if (Voxgig::Struct::islist($resdata) && @$resdata && $entity) {
      my @entities;
      for my $entry (@$resdata) {
        my $ent = $entity->make;
        $ent->data_set($entry) if Voxgig::Struct::ismap($entry);
        push @entities, $ent;
      }
      $result->{resdata} = \@entities;
    }
  }

  $ctx->{ctrl}{explain}{result} = $result if $ctx->{ctrl}{explain};
  return ($result, undef);
};

1;
