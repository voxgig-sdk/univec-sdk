package KOTLINPACKAGE.feature

import java.util.regex.Pattern

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.SdkClient

// Outbound HTTP(S) proxy support. Wraps the active transport and annotates
// each request's fetch definition with the proxy target (`fetchdef.proxy`).
// The proxy target comes from options (`url`) or, when `fromEnv` is set, the
// standard HTTPS_PROXY / HTTP_PROXY / NO_PROXY env vars.
class ProxyFeature : BaseFeature("proxy", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var noProxy: MutableList<String> = mutableListOf()

  // Activity tracking (mirrors the ts client._proxy record).
  var routed = 0
  var url = ""

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) {
      return
    }

    this.url = FeatureOptions.foptStr(this.options, "url", "")
    var noProxyRaw = FeatureOptions.foptStrList(this.options, "noProxy")

    if (FeatureOptions.foptBool(this.options, "fromEnv", false)) {
      if ("" == this.url) {
        this.url = firstEnv("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy")
      }
      if (noProxyRaw == null) {
        val np = firstEnv("NO_PROXY", "no_proxy")
        if ("" != np) {
          noProxyRaw = np.split(",").toMutableList()
        }
      }
    }

    this.noProxy = mutableListOf()
    if (noProxyRaw != null) {
      for (npRaw in noProxyRaw) {
        val np = npRaw.trim()
        if ("" != np) {
          this.noProxy.add(np)
        }
      }
    }

    val inner: FetcherFn = ctx.utility!!.fetcher

    ctx.utility!!.fetcher = { ctx2, u, fetchdef -> inner(ctx2, u, route(u, fetchdef)) }
  }

  private fun route(u: String, fetchdef: MutableMap<String, Any?>): MutableMap<String, Any?> {
    if ("" == this.url || bypass(u)) {
      return fetchdef
    }

    val out = LinkedHashMap(fetchdef)
    out["proxy"] = this.url

    this.routed++
    return out
  }

  private fun bypass(u: String): Boolean {
    if (this.noProxy.isEmpty()) {
      return false
    }
    var host = u
    val mm = HOST_RE.matcher(u)
    if (mm.find()) {
      host = mm.group(1)
    }
    for (np in this.noProxy) {
      if ("*" == np) {
        return true
      }
      val suffix = if (np.startsWith(".")) np.substring(1) else np
      if (host == np || host.endsWith(".$suffix")) {
        return true
      }
    }
    return false
  }

  companion object {
    private val HOST_RE: Pattern =
      Pattern.compile("^[a-z]+://([^/:]+)", Pattern.CASE_INSENSITIVE)

    private fun firstEnv(vararg names: String): String {
      for (name in names) {
        val v = System.getenv(name)
        if (v != null && "" != v) {
          return v
        }
      }
      return ""
    }
  }
}
