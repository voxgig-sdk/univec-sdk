# Univec SDK feature factory

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/feature/base_feature.pm"));
require(Cwd::abs_path("$__dir/feature/audit_feature.pm"));
require(Cwd::abs_path("$__dir/feature/cache_feature.pm"));
require(Cwd::abs_path("$__dir/feature/clienttrack_feature.pm"));
require(Cwd::abs_path("$__dir/feature/cost_feature.pm"));
require(Cwd::abs_path("$__dir/feature/debug_feature.pm"));
require(Cwd::abs_path("$__dir/feature/idempotency_feature.pm"));
require(Cwd::abs_path("$__dir/feature/log_feature.pm"));
require(Cwd::abs_path("$__dir/feature/metrics_feature.pm"));
require(Cwd::abs_path("$__dir/feature/netsim_feature.pm"));
require(Cwd::abs_path("$__dir/feature/paging_feature.pm"));
require(Cwd::abs_path("$__dir/feature/proxy_feature.pm"));
require(Cwd::abs_path("$__dir/feature/ratelimit_feature.pm"));
require(Cwd::abs_path("$__dir/feature/rbac_feature.pm"));
require(Cwd::abs_path("$__dir/feature/retry_feature.pm"));
require(Cwd::abs_path("$__dir/feature/streaming_feature.pm"));
require(Cwd::abs_path("$__dir/feature/telemetry_feature.pm"));
require(Cwd::abs_path("$__dir/feature/test_feature.pm"));
require(Cwd::abs_path("$__dir/feature/timeout_feature.pm"));

package UnivecFeatures;

sub make_feature {
  my ($name) = @_;
  $name = '' unless defined $name;
  return UnivecBaseFeature->new if 'base' eq $name;
  return UnivecAuditFeature->new if 'audit' eq $name;
  return UnivecCacheFeature->new if 'cache' eq $name;
  return UnivecClienttrackFeature->new if 'clienttrack' eq $name;
  return UnivecCostFeature->new if 'cost' eq $name;
  return UnivecDebugFeature->new if 'debug' eq $name;
  return UnivecIdempotencyFeature->new if 'idempotency' eq $name;
  return UnivecLogFeature->new if 'log' eq $name;
  return UnivecMetricsFeature->new if 'metrics' eq $name;
  return UnivecNetsimFeature->new if 'netsim' eq $name;
  return UnivecPagingFeature->new if 'paging' eq $name;
  return UnivecProxyFeature->new if 'proxy' eq $name;
  return UnivecRatelimitFeature->new if 'ratelimit' eq $name;
  return UnivecRbacFeature->new if 'rbac' eq $name;
  return UnivecRetryFeature->new if 'retry' eq $name;
  return UnivecStreamingFeature->new if 'streaming' eq $name;
  return UnivecTelemetryFeature->new if 'telemetry' eq $name;
  return UnivecTestFeature->new if 'test' eq $name;
  return UnivecTimeoutFeature->new if 'timeout' eq $name;
  return UnivecBaseFeature->new;
}

1;
