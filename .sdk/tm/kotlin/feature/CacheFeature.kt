package KOTLINPACKAGE.feature

import java.util.function.Supplier

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.FetcherFn
import KOTLINPACKAGE.core.SdkClient

// Response caching for safe (read) requests. Wraps the active transport and
// serves a fresh cached snapshot instead of hitting the network when the same
// method+URL was fetched within `ttl` ms (default: 5000). Only successful
// (2xx) responses to cacheable methods (default: GET) are stored.
@Suppress("UNCHECKED_CAST")
class CacheFeature : BaseFeature("cache", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null
  private var store: MutableMap<String, CacheEntry> = linkedMapOf()
  private var order: MutableList<String> = mutableListOf()

  // Activity tracking (mirrors the ts client._cache record).
  var hit = 0
  var miss = 0
  var bypass = 0

  private class CacheEntry {
    var expiry: Long = 0
    lateinit var snapshot: CacheSnapshot
  }

  private class CacheSnapshot {
    var status: Int = 0
    var statusText: String = ""
    var data: Any? = null
    var headers: MutableMap<String, Any?> = linkedMapOf()
  }

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) {
      return
    }

    this.store = linkedMapOf()
    this.order = mutableListOf()

    val inner: FetcherFn = ctx.utility!!.fetcher

    ctx.utility!!.fetcher = { ctx2, url, fetchdef -> through(ctx2, url, fetchdef, inner) }
  }

  private fun through(ctx: Context, url: String, fetchdef: MutableMap<String, Any?>, inner: FetcherFn): Any? {
    var method = "GET"
    val m = fetchdef["method"]
    if (m is String && "" != m) {
      method = m.uppercase()
    }

    var methods: List<String>? = FeatureOptions.foptStrList(this.options, "methods")
    if (methods == null) {
      methods = listOf("GET")
    }
    var cacheable = false
    for (cm in methods) {
      if (cm.uppercase() == method) {
        cacheable = true
        break
      }
    }
    if (!cacheable) {
      return inner(ctx, url, fetchdef)
    }

    val key = "$method $url"
    val now = FeatureOptions.foptNow(this.options).getAsLong()

    val hitEntry = this.store[key]
    if (hitEntry != null && hitEntry.expiry > now) {
      this.hit++
      return replay(hitEntry.snapshot)
    }

    val res: Any?
    try {
      res = inner(ctx, url, fetchdef)
    } catch (err: RuntimeException) {
      this.bypass++
      throw err
    }

    if (storable(res)) {
      val snapshot = snapshot(res)
      val ttl = FeatureOptions.foptInt(this.options, "ttl", 5000)
      evict()
      val entry = CacheEntry()
      entry.expiry = now + ttl
      entry.snapshot = snapshot
      this.store[key] = entry
      this.order.add(key)
      this.miss++
      return replay(snapshot)
    }

    this.bypass++
    return res
  }

  private fun storable(res: Any?): Boolean {
    val status = FeatureOptions.fresStatus(res)
    return status in 200..299
  }

  private fun snapshot(res: Any?): CacheSnapshot {
    val rm = if (res is MutableMap<*, *>) res as MutableMap<String, Any?> else null

    val snap = CacheSnapshot()

    val status = FeatureOptions.fresStatus(res)
    if (status >= 0) {
      snap.status = status
    }
    if (rm != null) {
      val st = rm["statusText"]
      if (st is String) {
        snap.statusText = st
      }
      val jf = rm["json"]
      if (jf is Supplier<*>) {
        snap.data = (jf as Supplier<Any?>).get()
      }
      val headers = rm["headers"]
      if (headers is MutableMap<*, *>) {
        for (h in (headers as MutableMap<String, Any?>).entries) {
          snap.headers[h.key.lowercase()] = h.value
        }
      }
    }

    return snap
  }

  // replay builds a fresh transport-shaped response so the body stays
  // re-readable for every consumer.
  private fun replay(snap: CacheSnapshot): MutableMap<String, Any?> {
    val data = snap.data
    val headers = LinkedHashMap(snap.headers)
    val out = linkedMapOf<String, Any?>()
    out["status"] = snap.status
    out["statusText"] = snap.statusText
    out["body"] = "not-used"
    out["json"] = Supplier<Any?> { data }
    out["headers"] = headers
    return out
  }

  // evict drops oldest entries (FIFO) until the store is under `max`.
  private fun evict() {
    val max = FeatureOptions.foptInt(this.options, "max", 256)
    while (this.store.size >= max && this.order.isNotEmpty()) {
      val oldest = this.order.removeAt(0)
      this.store.remove(oldest)
    }
  }
}
