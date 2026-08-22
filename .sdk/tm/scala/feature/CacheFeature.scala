package SCALAPACKAGE.feature

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.function.Supplier
import SCALAPACKAGE.core.{Context, FetcherFn, SdkClient}

// Response caching for safe (read) requests. Wraps the active transport and
// serves a fresh cached snapshot instead of hitting the network when the
// same method+URL was fetched within `ttl` ms (default: 5000). Only
// successful (2xx) responses to cacheable methods (default: GET) are
// stored, keyed by method+URL. The cache is bounded (`max` entries, default
// 256, oldest evicted first) and every hit/miss/bypass is counted. Bodies
// are snapshotted on capture so both the current caller and later hits can
// re-read the JSON body repeatedly.
class CacheFeature extends BaseFeature("cache", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null
  private var store: JMap[String, CacheEntry] = null
  private var order: JList[String] = null

  // Activity tracking (mirrors the ts client._cache record).
  var hit: Int = 0
  var miss: Int = 0
  var bypass: Int = 0

  private class CacheEntry {
    var expiry: Long = 0
    var snapshot: CacheSnapshot = null
  }

  private class CacheSnapshot {
    var status: Int = 0
    var statusText: String = ""
    var data: Object = null
    var headers: JMap[String, Object] = new LinkedHashMap[String, Object]()
  }

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)

    if (!this.active) {
      return
    }

    this.store = new LinkedHashMap[String, CacheEntry]()
    this.order = new ArrayList[String]()

    val inner: FetcherFn = ctx.utility.fetcher

    ctx.utility.fetcher = (ctx2, url, fetchdef) => through(ctx2, url, fetchdef, inner)
  }

  private def through(ctx: Context, url: String, fetchdef: JMap[String, Object],
      inner: FetcherFn): Object = {

    var method = "GET"
    val m = fetchdef.get("method")
    m match {
      case s: String if s != "" => method = s.toUpperCase()
      case _ =>
    }

    var methods = FeatureOptions.foptStrList(this.options, "methods")
    if (methods == null) {
      methods = java.util.List.of("GET")
    }
    var cacheable = false
    val mit = methods.iterator()
    while (!cacheable && mit.hasNext) {
      val cm = mit.next()
      if (cm.toUpperCase().equals(method)) {
        cacheable = true
      }
    }
    if (!cacheable) {
      return inner(ctx, url, fetchdef)
    }

    val key = method + " " + url
    val now = FeatureOptions.foptNow(this.options).getAsLong()

    val hitEntry = this.store.get(key)
    if (hitEntry != null && hitEntry.expiry > now) {
      this.hit += 1
      return replay(hitEntry.snapshot)
    }

    var res: Object = null
    try {
      res = inner(ctx, url, fetchdef)
    } catch {
      case err: RuntimeException =>
        this.bypass += 1
        throw err
    }

    if (storable(res)) {
      val snapshot = this.snapshot(res)
      val ttl = FeatureOptions.foptInt(this.options, "ttl", 5000)
      evict()
      val entry = new CacheEntry()
      entry.expiry = now + ttl
      entry.snapshot = snapshot
      this.store.put(key, entry)
      this.order.add(key)
      this.miss += 1
      return replay(snapshot)
    }

    this.bypass += 1
    res
  }

  private def storable(res: Object): Boolean = {
    val status = FeatureOptions.fresStatus(res)
    status >= 200 && status < 300
  }

  private def snapshot(res: Object): CacheSnapshot = {
    val rm: JMap[String, Object] = res match {
      case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
      case _ => null
    }

    val snap = new CacheSnapshot()

    val status = FeatureOptions.fresStatus(res)
    if (status >= 0) {
      snap.status = status
    }
    if (rm != null) {
      rm.get("statusText") match {
        case st: String => snap.statusText = st
        case _ =>
      }
      rm.get("json") match {
        case jf: Supplier[_] => snap.data = jf.asInstanceOf[Supplier[Object]].get()
        case _ =>
      }
      rm.get("headers") match {
        case hm0: JMap[_, _] =>
          val hm = hm0.asInstanceOf[JMap[String, Object]]
          val it = hm.entrySet().iterator()
          while (it.hasNext) {
            val h = it.next()
            snap.headers.put(h.getKey.toLowerCase(), h.getValue)
          }
        case _ =>
      }
    }

    snap
  }

  // replay builds a fresh transport-shaped response so the body stays
  // re-readable for every consumer.
  private def replay(snap: CacheSnapshot): JMap[String, Object] = {
    val data = snap.data
    val headers = new LinkedHashMap[String, Object](snap.headers)
    val out = new LinkedHashMap[String, Object]()
    out.put("status", java.lang.Integer.valueOf(snap.status))
    out.put("statusText", snap.statusText)
    out.put("body", "not-used")
    val js: Supplier[Object] = () => data
    out.put("json", js)
    out.put("headers", headers)
    out
  }

  // evict drops oldest entries (FIFO) until the store is under `max`.
  private def evict(): Unit = {
    val max = FeatureOptions.foptInt(this.options, "max", 256)
    while (this.store.size() >= max && !this.order.isEmpty) {
      val oldest = this.order.remove(0)
      this.store.remove(oldest)
    }
  }
}
