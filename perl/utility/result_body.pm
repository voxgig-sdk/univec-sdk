# Univec SDK utility: result_body

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{result_body} = sub {
  my ($ctx) = @_;
  my $response = $ctx->{response};
  my $result = $ctx->{result};
  if ($result && $response && $response->{json_func}
    && UnivecHelpers::rb_truthy($response->{body})) {
    $result->{body} = $response->{json_func}->();
  }
  return $result;
};

1;
