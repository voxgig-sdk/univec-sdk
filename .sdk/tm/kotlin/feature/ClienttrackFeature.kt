package KOTLINPACKAGE.feature

import java.util.concurrent.ThreadLocalRandom
import java.util.function.Function

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.SdkClient

// Client tracking. Establishes a stable per-client session id at construction
// and stamps identifying headers on every request: a `User-Agent`, an
// `X-Client-Id` (session), and a fresh per-request `X-Request-Id`.
@Suppress("UNCHECKED_CAST")
class ClienttrackFeature : BaseFeature("clienttrack", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null

  // Activity tracking (mirrors the ts client._clienttrack record).
  var session = ""
  var requests = 0
  var lastRequestId = ""
  var clientName = ""

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    this.requests = 0
  }

  override fun postConstruct(ctx: Context) {
    if (!this.active) {
      return
    }
    this.session = FeatureOptions.foptStr(this.options, "sessionId", genid("session"))
    this.clientName = name()
  }

  override fun preRequest(ctx: Context) {
    if (!this.active) {
      return
    }

    val spec = ctx.spec ?: return

    // Lazily establish the session when PostConstruct never fired.
    if ("" == this.session) {
      this.session = FeatureOptions.foptStr(this.options, "sessionId", genid("session"))
    }

    val h = FeatureOptions.foptMap(this.options, "headers")
    this.requests++
    val requestId = genid("request")

    FeatureOptions.fheaderSetDefault(spec.headers, FeatureOptions.foptStr(h, "agent", "User-Agent"), name())
    FeatureOptions.fheaderSetDefault(spec.headers, FeatureOptions.foptStr(h, "client", "X-Client-Id"), this.session)
    spec.headers[FeatureOptions.foptStr(h, "request", "X-Request-Id")] = requestId

    this.lastRequestId = requestId
    this.clientName = name()
  }

  private fun name(): String {
    val name = FeatureOptions.foptStr(this.options, "clientName", "Univec-SDK")
    val version = FeatureOptions.foptStr(this.options, "clientVersion", "0.0.1")
    return "$name/$version"
  }

  private fun genid(kind: String): String {
    val ig = this.options?.get("idgen")
    if (ig is Function<*, *>) {
      return (ig as Function<String, String>).apply(kind)
    }
    val r = ThreadLocalRandom.current()
    var id = String.format(
      "%s-%06x%06x%06x", kind.substring(0, 1),
      r.nextInt(0x1000000), r.nextInt(0x1000000), r.nextInt(0x1000000),
    )
    if (id.length > 20) {
      id = id.substring(0, 20)
    }
    return id
  }
}
