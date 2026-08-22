# Univec SDK utility: make_fetch_def

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/result.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{make_fetch_def} = sub {
  my ($ctx) = @_;
  my $spec = $ctx->{spec};
  return (undef, $ctx->make_error('fetchdef_no_spec',
    'Expected context spec property to be defined.')) unless $spec;

  $ctx->{result} = UnivecResult->new({}) unless $ctx->{result};
  $spec->{step} = 'prepare';

  my ($url, $err) = $ctx->{utility}{make_url}->($ctx);
  return (undef, $err) if $err;

  $spec->{url} = $url;

  my $fetchdef = {
    'url' => $url,
    'method' => $spec->{method},
    'headers' => $spec->{headers},
  };
  if (UnivecHelpers::rb_truthy($spec->{body})) {
    $fetchdef->{body} = Voxgig::Struct::ismap($spec->{body})
      ? Voxgig::Struct::jsonify($spec->{body})
      : $spec->{body};
  }

  return ($fetchdef, undef);
};

1;
