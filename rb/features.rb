# Univec SDK feature factory

require_relative 'feature/base_feature'
require_relative 'feature/audit_feature'
require_relative 'feature/cache_feature'
require_relative 'feature/clienttrack_feature'
require_relative 'feature/cost_feature'
require_relative 'feature/debug_feature'
require_relative 'feature/idempotency_feature'
require_relative 'feature/log_feature'
require_relative 'feature/metrics_feature'
require_relative 'feature/netsim_feature'
require_relative 'feature/paging_feature'
require_relative 'feature/proxy_feature'
require_relative 'feature/ratelimit_feature'
require_relative 'feature/rbac_feature'
require_relative 'feature/retry_feature'
require_relative 'feature/streaming_feature'
require_relative 'feature/telemetry_feature'
require_relative 'feature/test_feature'
require_relative 'feature/timeout_feature'


module UnivecFeatures
  def self.make_feature(name)
    case name
    when "base"
      UnivecBaseFeature.new
    when "audit"
      UnivecAuditFeature.new
    when "cache"
      UnivecCacheFeature.new
    when "clienttrack"
      UnivecClienttrackFeature.new
    when "cost"
      UnivecCostFeature.new
    when "debug"
      UnivecDebugFeature.new
    when "idempotency"
      UnivecIdempotencyFeature.new
    when "log"
      UnivecLogFeature.new
    when "metrics"
      UnivecMetricsFeature.new
    when "netsim"
      UnivecNetsimFeature.new
    when "paging"
      UnivecPagingFeature.new
    when "proxy"
      UnivecProxyFeature.new
    when "ratelimit"
      UnivecRatelimitFeature.new
    when "rbac"
      UnivecRbacFeature.new
    when "retry"
      UnivecRetryFeature.new
    when "streaming"
      UnivecStreamingFeature.new
    when "telemetry"
      UnivecTelemetryFeature.new
    when "test"
      UnivecTestFeature.new
    when "timeout"
      UnivecTimeoutFeature.new
    else
      UnivecBaseFeature.new
    end
  end
end
