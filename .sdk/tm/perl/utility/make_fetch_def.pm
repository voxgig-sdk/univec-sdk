# Univec SDK utility: make_fetch_def

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/result.pm"));
require(Cwd::abs_path("$__dir/media.pm"));

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
  my $body = $spec->{body};
  if (defined $body && !Voxgig::Struct::is_none($body) && !Voxgig::Struct::is_jnull($body)) {
    $fetchdef->{body} = request_body($ctx->{point}, $body);
  }

  return ($fetchdef, undef);
};

1;
