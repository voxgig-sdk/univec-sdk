package SCALAPACKAGE.feature

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.regex.{Matcher, Pattern}
import SCALAPACKAGE.core.{Context, FetcherFn, SdkClient}

// Outbound HTTP(S) proxy support. Wraps the active transport and annotates
// each request's fetch definition with the proxy target (`fetchdef.proxy`).
// The default HttpClient transport honours the annotation by routing the
// request through a proxied client (see utility/Fetcher.java); custom
// transports can do the same. The proxy target comes from options (`url`)
// or, when `fromEnv` is set, the standard HTTPS_PROXY / HTTP_PROXY /
// NO_PROXY environment variables. Hosts matching `noProxy` bypass the proxy.
class ProxyFeature extends BaseFeature("proxy", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var noProxy: JList[String] = new ArrayList[String]()

  // Activity tracking (mirrors the ts client._proxy record).
  var routed: Int = 0
  var url: String = ""

  private val HOST_RE: Pattern =
    Pattern.compile("^[a-z]+://([^/:]+)", Pattern.CASE_INSENSITIVE)

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) {
      return
    }

    this.url = FeatureOptions.foptStr(this.options, "url", "")
    var noProxyRaw = FeatureOptions.foptStrList(this.options, "noProxy")

    if (FeatureOptions.foptBool(this.options, "fromEnv", false)) {
      if ("".equals(this.url)) {
        this.url = firstEnv("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy")
      }
      if (noProxyRaw == null) {
        val np = firstEnv("NO_PROXY", "no_proxy")
        if (!"".equals(np)) {
          noProxyRaw = new ArrayList[String](java.util.List.of(np.split(",")*))
        }
      }
    }

    this.noProxy = new ArrayList[String]()
    if (noProxyRaw != null) {
      val it = noProxyRaw.iterator()
      while (it.hasNext) {
        val np = it.next().trim()
        if (!"".equals(np)) {
          this.noProxy.add(np)
        }
      }
    }

    val inner: FetcherFn = ctx.utility.fetcher

    ctx.utility.fetcher = (ctx2, u, fetchdef) => inner(ctx2, u, route(u, fetchdef))
  }

  private def route(u: String, fetchdef: JMap[String, Object]): JMap[String, Object] = {
    if ("".equals(this.url) || bypass(u)) {
      return fetchdef
    }

    val out = new LinkedHashMap[String, Object](fetchdef)
    out.put("proxy", this.url)

    this.routed += 1
    out
  }

  private def bypass(u: String): Boolean = {
    if (this.noProxy.isEmpty) {
      return false
    }
    var host = u
    val m = HOST_RE.matcher(u)
    if (m.find()) {
      host = m.group(1)
    }
    val it = this.noProxy.iterator()
    while (it.hasNext) {
      val np = it.next()
      if ("*".equals(np)) {
        return true
      }
      val suffix = if (np.startsWith(".")) np.substring(1) else np
      if (host.equals(np) || host.endsWith("." + suffix)) {
        return true
      }
    }
    false
  }

  private def firstEnv(names: String*): String = {
    val it = names.iterator
    while (it.hasNext) {
      val name = it.next()
      val v = System.getenv(name)
      if (v != null && !"".equals(v)) {
        return v
      }
    }
    ""
  }
}
