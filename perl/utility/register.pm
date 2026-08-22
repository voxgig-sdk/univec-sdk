# Univec SDK utility registration

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }

require(Cwd::abs_path("$__dir/../core/utility_type.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/clean.pm"));
require(Cwd::abs_path("$__dir/done.pm"));
require(Cwd::abs_path("$__dir/make_error.pm"));
require(Cwd::abs_path("$__dir/feature_add.pm"));
require(Cwd::abs_path("$__dir/feature_hook.pm"));
require(Cwd::abs_path("$__dir/feature_init.pm"));
require(Cwd::abs_path("$__dir/fetcher.pm"));
require(Cwd::abs_path("$__dir/make_fetch_def.pm"));
require(Cwd::abs_path("$__dir/make_context.pm"));
require(Cwd::abs_path("$__dir/make_options.pm"));
require(Cwd::abs_path("$__dir/make_request.pm"));
require(Cwd::abs_path("$__dir/make_response.pm"));
require(Cwd::abs_path("$__dir/make_result.pm"));
require(Cwd::abs_path("$__dir/make_point.pm"));
require(Cwd::abs_path("$__dir/make_spec.pm"));
require(Cwd::abs_path("$__dir/make_url.pm"));
require(Cwd::abs_path("$__dir/param.pm"));
require(Cwd::abs_path("$__dir/prepare_auth.pm"));
require(Cwd::abs_path("$__dir/prepare_body.pm"));
require(Cwd::abs_path("$__dir/prepare_headers.pm"));
require(Cwd::abs_path("$__dir/prepare_method.pm"));
require(Cwd::abs_path("$__dir/prepare_params.pm"));
require(Cwd::abs_path("$__dir/prepare_path.pm"));
require(Cwd::abs_path("$__dir/prepare_query.pm"));
require(Cwd::abs_path("$__dir/graphql.pm"));
require(Cwd::abs_path("$__dir/result_basic.pm"));
require(Cwd::abs_path("$__dir/result_body.pm"));
require(Cwd::abs_path("$__dir/result_headers.pm"));
require(Cwd::abs_path("$__dir/transform_request.pm"));
require(Cwd::abs_path("$__dir/transform_response.pm"));

$UnivecUtility::REGISTRAR = sub {
  my ($u) = @_;
  for my $k (keys %UnivecUtilities::REGISTRY) {
    $u->{$k} = $UnivecUtilities::REGISTRY{$k};
  }
  # The vendored struct utility, reachable as $utility->{struct}{<fn>}.
  $u->{struct} = UnivecHelpers::struct_facade();
};

1;
