package = "voxgig-sdk-univec"
version = "0.1.2-1"
source = {
  -- git+https (GitHub dropped git:// in 2022); pin the install to the release
  -- tag pushed by `make publish`, and point at the lua/ subdir of the monorepo.
  url = "git+https://github.com/voxgig-sdk/univec-sdk.git",
  tag = "lua/v0.1.2",
  dir = "univec-sdk/lua"
}
description = {
  summary = "Unofficial generated Lua SDK for the UniVec public API. Not affiliated with or endorsed by the upstream API provider.",
  homepage = "https://github.com/voxgig-sdk/univec-sdk",
  issues_url = "https://github.com/voxgig-sdk/univec-sdk/issues",
  license = "MIT",
  labels = { "voxgig", "sdk", "generated-sdk", "openapi", "api-client", "univec" }
}
dependencies = {
  "lua >= 5.3",
  "dkjson >= 2.5",
}
build = {
  type = "builtin",
  modules = {
    ["univec_sdk"] = "univec_sdk.lua",
    ["config"] = "config.lua",
    ["config_shared"] = "config_shared.lua",
    ["config_plugins"] = "config_plugins.lua",
    ["features"] = "features.lua",
    ["feature.base_feature"] = "feature/base_feature.lua",
    ["feature.audit_feature"] = "feature/audit_feature.lua",
    ["feature.cache_feature"] = "feature/cache_feature.lua",
    ["feature.clienttrack_feature"] = "feature/clienttrack_feature.lua",
    ["feature.cost_feature"] = "feature/cost_feature.lua",
    ["feature.debug_feature"] = "feature/debug_feature.lua",
    ["feature.idempotency_feature"] = "feature/idempotency_feature.lua",
    ["feature.log_feature"] = "feature/log_feature.lua",
    ["feature.metrics_feature"] = "feature/metrics_feature.lua",
    ["feature.netsim_feature"] = "feature/netsim_feature.lua",
    ["feature.paging_feature"] = "feature/paging_feature.lua",
    ["feature.proxy_feature"] = "feature/proxy_feature.lua",
    ["feature.ratelimit_feature"] = "feature/ratelimit_feature.lua",
    ["feature.rbac_feature"] = "feature/rbac_feature.lua",
    ["feature.retry_feature"] = "feature/retry_feature.lua",
    ["feature.secrets_feature"] = "feature/secrets_feature.lua",
    ["feature.secrets.plugin"] = "feature/secrets/plugin.lua",
    ["feature.secrets.plugin.capability"] = "feature/secrets/plugin/capability.lua",
    ["feature.secrets.plugin.catalog"] = "feature/secrets/plugin/catalog.lua",
    ["feature.secrets.plugin.config"] = "feature/secrets/plugin/config.lua",
    ["feature.secrets.plugin.depend"] = "feature/secrets/plugin/depend.lua",
    ["feature.secrets.plugin.env"] = "feature/secrets/plugin/env.lua",
    ["feature.secrets.plugin.export"] = "feature/secrets/plugin/export.lua",
    ["feature.secrets.plugin.graph"] = "feature/secrets/plugin/graph.lua",
    ["feature.secrets.plugin.host"] = "feature/secrets/plugin/host.lua",
    ["feature.secrets.plugin.json"] = "feature/secrets/plugin/json.lua",
    ["feature.secrets.plugin.order"] = "feature/secrets/plugin/order.lua",
    ["feature.secrets.plugin.point"] = "feature/secrets/plugin/point.lua",
    ["feature.secrets.plugin.ref"] = "feature/secrets/plugin/ref.lua",
    ["feature.secrets.plugin.resolve"] = "feature/secrets/plugin/resolve.lua",
    ["feature.secrets.plugin.types"] = "feature/secrets/plugin/types.lua",
    ["feature.secrets.plugin.version"] = "feature/secrets/plugin/version.lua",
    ["feature.secrets.sekreto"] = "feature/secrets/sekreto.lua",
    ["feature.secrets.sekreto.addr"] = "feature/secrets/sekreto/addr.lua",
    ["feature.secrets.sekreto.err"] = "feature/secrets/sekreto/err.lua",
    ["feature.secrets.sekreto.name"] = "feature/secrets/sekreto/name.lua",
    ["feature.secrets.sekreto.plugins.boru"] = "feature/secrets/sekreto/plugins/boru.lua",
    ["feature.secrets.sekreto.plugins.crypto"] = "feature/secrets/sekreto/plugins/crypto.lua",
    ["feature.secrets.sekreto.plugins.hashicorp"] = "feature/secrets/sekreto/plugins/hashicorp.lua",
    ["feature.secrets.sekreto.plugins.httpjson"] = "feature/secrets/sekreto/plugins/httpjson.lua",
    ["feature.secrets.sekreto.plugins.json"] = "feature/secrets/sekreto/plugins/json.lua",
    ["feature.secrets.sekreto.plugins.net"] = "feature/secrets/sekreto/plugins/net.lua",
    ["feature.secrets.sekreto.plugins.support"] = "feature/secrets/sekreto/plugins/support.lua",
    ["feature.secrets.sekreto.providers"] = "feature/secrets/sekreto/providers.lua",
    ["feature.streaming_feature"] = "feature/streaming_feature.lua",
    ["feature.telemetry_feature"] = "feature/telemetry_feature.lua",
    ["feature.test_feature"] = "feature/test_feature.lua",
    ["feature.timeout_feature"] = "feature/timeout_feature.lua",
  }
}
