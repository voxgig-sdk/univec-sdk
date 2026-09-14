# Univec SDK feature factory

defmodule Univec.Features do
  def make_feature(name) do
    case name do
      "audit" -> Univec.Feature.Audit.new()
      "cache" -> Univec.Feature.Cache.new()
      "clienttrack" -> Univec.Feature.Clienttrack.new()
      "cost" -> Univec.Feature.Cost.new()
      "debug" -> Univec.Feature.Debug.new()
      "idempotency" -> Univec.Feature.Idempotency.new()
      "log" -> Univec.Feature.Log.new()
      "metrics" -> Univec.Feature.Metrics.new()
      "netsim" -> Univec.Feature.Netsim.new()
      "paging" -> Univec.Feature.Paging.new()
      "proxy" -> Univec.Feature.Proxy.new()
      "ratelimit" -> Univec.Feature.Ratelimit.new()
      "rbac" -> Univec.Feature.Rbac.new()
      "retry" -> Univec.Feature.Retry.new()
      "secrets" -> Univec.Feature.Secrets.new()
      "streaming" -> Univec.Feature.Streaming.new()
      "telemetry" -> Univec.Feature.Telemetry.new()
      "test" -> Univec.Feature.Test.new()
      "timeout" -> Univec.Feature.Timeout.new()
      _ -> Univec.Feature.new()
    end
  end
end
