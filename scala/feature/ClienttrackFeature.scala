package voxgig.univecsdk.feature

import java.util.{LinkedHashMap, Map => JMap}
import java.util.concurrent.ThreadLocalRandom
import voxgig.univecsdk.core.{Context, SdkClient}

// Client tracking. Establishes a stable per-client session id at
// construction and stamps identifying headers on every request: a
// `User-Agent` (`<clientName>/<clientVersion>`), an `X-Client-Id` (session),
// and a fresh per-request `X-Request-Id`. This lets a server correlate all
// traffic from one SDK instance and each individual call. Header names,
// client name/version and the id generator (`idgen`) are configurable;
// caller-provided User-Agent / X-Client-Id values are never clobbered.
class ClienttrackFeature extends BaseFeature("clienttrack", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null

  // Activity tracking (mirrors the ts client._clienttrack record).
  var session: String = ""
  var requests: Int = 0
  var lastRequestId: String = ""
  var clientName: String = ""

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
    this.requests = 0
  }

  override def postConstruct(ctx: Context): Unit = {
    if (!this.active) {
      return
    }
    this.session = FeatureOptions.foptStr(this.options, "sessionId", genid("session"))
    this.clientName = agentName()
  }

  override def preRequest(ctx: Context): Unit = {
    if (!this.active) {
      return
    }

    val spec = ctx.spec
    if (spec == null) {
      return
    }
    if (spec.headers == null) {
      spec.headers = new LinkedHashMap[String, Object]()
    }

    // Lazily establish the session when PostConstruct never fired.
    if ("".equals(this.session)) {
      this.session = FeatureOptions.foptStr(this.options, "sessionId", genid("session"))
    }

    val h = FeatureOptions.foptMap(this.options, "headers")
    this.requests += 1
    val requestId = genid("request")

    FeatureOptions.fheaderSetDefault(spec.headers,
      FeatureOptions.foptStr(h, "agent", "User-Agent"), agentName())
    FeatureOptions.fheaderSetDefault(spec.headers,
      FeatureOptions.foptStr(h, "client", "X-Client-Id"), this.session)
    spec.headers.put(FeatureOptions.foptStr(h, "request", "X-Request-Id"), requestId)

    this.lastRequestId = requestId
    this.clientName = agentName()
  }

  private def agentName(): String = {
    val name = FeatureOptions.foptStr(this.options, "clientName", "Univec-SDK")
    val version = FeatureOptions.foptStr(this.options, "clientVersion", "0.0.1")
    name + "/" + version
  }

  private def genid(kind: String): String = {
    this.options.get("idgen") match {
      case f: java.util.function.Function[_, _] =>
        return f.asInstanceOf[java.util.function.Function[String, String]].apply(kind)
      case _ =>
    }
    val r = ThreadLocalRandom.current()
    var id = String.format("%s-%06x%06x%06x", kind.substring(0, 1),
      java.lang.Integer.valueOf(r.nextInt(0x1000000)), java.lang.Integer.valueOf(r.nextInt(0x1000000)),
      java.lang.Integer.valueOf(r.nextInt(0x1000000)))
    if (id.length() > 20) {
      id = id.substring(0, 20)
    }
    id
  }
}
