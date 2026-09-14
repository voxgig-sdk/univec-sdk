-- Univec SDK feature factory

local BaseFeature = require("feature.base_feature")
local AuditFeature = require("feature.audit_feature")
local CacheFeature = require("feature.cache_feature")
local ClienttrackFeature = require("feature.clienttrack_feature")
local CostFeature = require("feature.cost_feature")
local DebugFeature = require("feature.debug_feature")
local IdempotencyFeature = require("feature.idempotency_feature")
local LogFeature = require("feature.log_feature")
local MetricsFeature = require("feature.metrics_feature")
local NetsimFeature = require("feature.netsim_feature")
local PagingFeature = require("feature.paging_feature")
local ProxyFeature = require("feature.proxy_feature")
local RatelimitFeature = require("feature.ratelimit_feature")
local RbacFeature = require("feature.rbac_feature")
local RetryFeature = require("feature.retry_feature")
local SecretsFeature = require("feature.secrets_feature")
local StreamingFeature = require("feature.streaming_feature")
local TelemetryFeature = require("feature.telemetry_feature")
local TestFeature = require("feature.test_feature")
local TimeoutFeature = require("feature.timeout_feature")


local features = {}

features.base = function()
  return BaseFeature.new()
end

features["audit"] = function()
  return AuditFeature.new()
end

features["cache"] = function()
  return CacheFeature.new()
end

features["clienttrack"] = function()
  return ClienttrackFeature.new()
end

features["cost"] = function()
  return CostFeature.new()
end

features["debug"] = function()
  return DebugFeature.new()
end

features["idempotency"] = function()
  return IdempotencyFeature.new()
end

features["log"] = function()
  return LogFeature.new()
end

features["metrics"] = function()
  return MetricsFeature.new()
end

features["netsim"] = function()
  return NetsimFeature.new()
end

features["paging"] = function()
  return PagingFeature.new()
end

features["proxy"] = function()
  return ProxyFeature.new()
end

features["ratelimit"] = function()
  return RatelimitFeature.new()
end

features["rbac"] = function()
  return RbacFeature.new()
end

features["retry"] = function()
  return RetryFeature.new()
end

features["secrets"] = function()
  return SecretsFeature.new()
end

features["streaming"] = function()
  return StreamingFeature.new()
end

features["telemetry"] = function()
  return TelemetryFeature.new()
end

features["test"] = function()
  return TestFeature.new()
end

features["timeout"] = function()
  return TimeoutFeature.new()
end


return features
