// Univec SDK - generated model configuration and feature
// factory. GENERATED from the API model - do not edit by hand.

import Foundation

public enum SdkConfig {
  public static func makeConfig() -> VMap {
    let json = #"""
{"main":{"name":"Univec","slug":"univec","version":"0.1.1","target":"swift"},"feature":{"audit":{"options":{"active":false,"actor":"anonymous","max":1000},"transport":"none"},"cache":{"options":{"active":false,"max":256,"methods":["GET"],"ttl":5000},"transport":"wrap"},"clienttrack":{"options":{"active":false,"clientVersion":"0.0.1"},"transport":"none"},"cost":{"options":{"active":false,"budget":0,"currency":"USD","header":"","onBudget":"warn","path":"","perUnit":0,"rates":{},"unit":0},"transport":"wrap"},"debug":{"options":{"active":false,"max":100,"redact":["authorization","cookie","set-cookie","api-key","apikey","x-api-key","idempotency-key"]},"transport":"none"},"idempotency":{"options":{"active":false,"header":"Idempotency-Key","methods":["POST","PUT","PATCH","DELETE"],"ops":["create","update","remove"]},"transport":"none"},"log":{"options":{"active":true},"transport":"none"},"metrics":{"options":{"active":false},"transport":"none"},"netsim":{"options":{"active":false,"errorTimes":0,"failEvery":0,"failRate":0,"failStatus":503,"failTimes":0,"latency":0,"offline":false,"rateLimitTimes":0,"retryAfter":0,"seed":1},"transport":"wrap"},"paging":{"options":{"active":false,"afterVar":"after","cursorParam":"cursor","firstVar":"first","limitParam":"limit","pageParam":"page","startPage":1},"transport":"none"},"proxy":{"options":{"active":false,"fromEnv":false,"noProxy":[],"url":""},"transport":"wrap"},"ratelimit":{"options":{"active":false,"burst":5,"rate":5},"transport":"wrap"},"rbac":{"options":{"active":false,"deny":false,"permissions":[],"rules":{}},"transport":"none"},"retry":{"options":{"active":false,"factor":2,"maxDelay":2000,"minDelay":50,"retries":2,"statuses":[408,425,429,500,502,503,504]},"transport":"wrap"},"streaming":{"options":{"active":false,"chunkDelay":0,"chunkSize":0},"transport":"none"},"telemetry":{"options":{"active":false},"transport":"none"},"test":{"options":{"active":false},"transport":"base"},"timeout":{"options":{"active":false,"ms":30000},"transport":"wrap"}},"options":{"base":"https://api.univec.ai","auth":{"prefix":"Bearer"},"headers":{"content-type":"application/json"},"entity":{"convert":{},"embed":{},"ephemeral_key":{},"model":{}}},"entity":{"convert":{"fields":[{"name":"bridge_model","req":true,"short":"Embed model used to vectorise the text before translation.","type":"`$STRING`"},{"name":"embeddings","req":true,"short":"Translated vectors, in the target model's dimension.","type":"`$ARRAY`"},{"name":"source_model","req":true,"short":"Model space the supplied vectors are currently in.","type":"`$STRING`"},{"name":"target_model","req":true,"short":"Model space to translate into.","type":"`$STRING`"},{"name":"texts","req":true,"short":"Texts to embed and translate.","type":"`$ARRAY`"}],"name":"convert","op":{"create":{"input":"data","name":"create","points":[{"args":{},"kind":"http","method":"POST","orig":"/v1/convert","segments":[{"lit":"v1"},{"lit":"convert"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"parts":["v1","convert"]},{"args":{},"kind":"http","method":"POST","orig":"/v1/embed-bridge","segments":[{"lit":"v1"},{"lit":"embed-bridge"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"parts":["v1","embed-bridge"]},{"args":{},"kind":"http","method":"POST","orig":"/v1/ephemeral/convert","segments":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"convert"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"parts":["v1","ephemeral","convert"]},{"args":{},"kind":"http","method":"POST","orig":"/v1/ephemeral/embed-bridge","segments":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"embed-bridge"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"parts":["v1","ephemeral","embed-bridge"]}]}},"relations":{"ancestors":[]}},"embed":{"fields":[{"name":"embeddings","req":true,"short":"One vector per input text, in input order.","type":"`$ARRAY`"},{"name":"model","req":true,"short":"Model that produced the vectors.","type":"`$STRING`"},{"name":"texts","req":true,"short":"Texts to embed.","type":"`$ARRAY`"}],"name":"embed","op":{"create":{"input":"data","name":"create","points":[{"args":{},"kind":"http","method":"POST","orig":"/v1/embed","segments":[{"lit":"v1"},{"lit":"embed"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"parts":["v1","embed"]},{"args":{},"kind":"http","method":"POST","orig":"/v1/ephemeral/embed","segments":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"embed"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"parts":["v1","ephemeral","embed"]}]}},"relations":{"ancestors":[]}},"ephemeral_key":{"fields":[{"name":"dailyLimit","req":true,"short":"Calls permitted per day.","type":"`$INTEGER`"},{"name":"dailyUsed","req":true,"short":"Calls already used today.","type":"`$INTEGER`"},{"name":"key","req":true,"short":"The ephemeral API key, prefixed `eph_`.","type":"`$STRING`"},{"format":"date-time","name":"resetsAt","req":true,"short":"When the daily allowance resets.","type":"`$STRING`"}],"name":"ephemeral_key","op":{"create":{"input":"data","name":"create","points":[{"args":{},"kind":"http","method":"POST","orig":"/v1/ephemeral/key","segments":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"key"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"parts":["v1","ephemeral","key"]}]}},"relations":{"ancestors":[]}},"model":{"fields":[{"name":"eval","short":"Retrieval-fidelity metrics for a convert model.","type":"`$OBJECT`"},{"name":"executionProvider","short":"Hardware backend, e.g.","type":"`$STRING`"},{"name":"modelCard","short":"Convert models only: training provenance and architecture detail.","type":"`$OBJECT`"},{"name":"modelType","req":true,"short":"`embed` for text-to-vector models, `convert` for space-translation models.","type":"`$STRING`"},{"name":"name","req":true,"short":"Model identifier used in requests.","type":"`$STRING`"},{"name":"sequenceLen","short":"Embed models only: maximum input sequence length.","type":"`$INTEGER`"},{"name":"sourceDim","short":"Convert models only: source vector dimension.","type":"`$INTEGER`"},{"name":"sourceModel","short":"Convert models only: the source model space.","type":"`$STRING`"},{"name":"targetDim","req":true,"short":"Dimension of the produced vectors.","type":"`$INTEGER`"},{"name":"targetModel","req":true,"short":"The model space produced.","type":"`$STRING`"}],"name":"model","op":{"list":{"input":"data","name":"list","points":[{"args":{},"kind":"http","method":"GET","orig":"/v1/models","segments":[{"lit":"v1"},{"lit":"models"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"parts":["v1","models"]}]}},"relations":{"ancestors":[]}}}}
"""#
    return (try? JSON.parse(json))?.asMap ?? VMap()
  }

  // SHARED CONFIG (sdkgen rung L2).
  //
  // The SDK reads the config on every request and never writes to it, so one
  // instance is shared by every client rather than rebuilt per client - the
  // difference between parsing the embedded JSON once and once per client.
  //
  // A static let in an enum is lazy and initialised exactly once, thread-safe
  // via swift_once.
  //
  // The result is SHARED: treat it as read-only. Callers that need to mutate
  // should use makeConfig, which always parses a fresh copy.
  private static let sharedConfigVal: VMap = makeConfig()

  public static func sharedConfig() -> VMap {
    return sharedConfigVal
  }

  public static func makeFeature(_ name: String) -> BaseFeature {
    switch name {
    case "audit": return AuditFeature()
    case "cache": return CacheFeature()
    case "clienttrack": return ClienttrackFeature()
    case "cost": return CostFeature()
    case "debug": return DebugFeature()
    case "idempotency": return IdempotencyFeature()
    case "log": return LogFeature()
    case "metrics": return MetricsFeature()
    case "netsim": return NetsimFeature()
    case "paging": return PagingFeature()
    case "proxy": return ProxyFeature()
    case "ratelimit": return RatelimitFeature()
    case "rbac": return RbacFeature()
    case "retry": return RetryFeature()
    case "streaming": return StreamingFeature()
    case "telemetry": return TelemetryFeature()
    case "test": return TestFeature()
    case "timeout": return TimeoutFeature()
    default: return BaseFeature()
    }
  }

  // The plugin definitions the model selected per feature, as [Any] so a
  // feature can consume them without core naming the plugin module's
  // types. Empty when no active feature declares active plugin groups for
  // this target.
  private static let featurePluginsVal: [String: [Any]] = [:]

  // featurePlugins is the definitions list for one feature's chain.
  public static func featurePlugins(_ name: String) -> [Any] {
    return featurePluginsVal[name] ?? []
  }
}
