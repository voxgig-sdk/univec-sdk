// Response caching for safe (read) requests. Wraps the active transport and
// serves a fresh cached snapshot instead of hitting the network when the same
// method+URL was fetched within `ttl` ms (default: 5000). Only successful
// (2xx) responses to cacheable methods (default: GET) are stored, keyed by
// method+URL. The cache is bounded (`max` entries, default 256, oldest evicted
// first) and every hit/miss/bypass is counted. Bodies are snapshotted on
// capture so both the current caller and later hits can re-read the JSON body
// repeatedly.

import Foundation

public final class CacheFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var store: [String: CacheEntry] = [:]
  private var order: [String] = []

  // Activity tracking (mirrors the ts client._cache record).
  public var hit = 0
  public var miss = 0
  public var bypass = 0

  private final class CacheEntry {
    var expiry: Int64 = 0
    var snapshot: CacheSnapshot = CacheSnapshot()
  }

  private final class CacheSnapshot {
    var status: Int = 0
    var statusText: String = ""
    var data: Value = .noval
    var headers: VMap = VMap()
  }

  public override init() {
    super.init()
    version = "0.0.1"
    name = "cache"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)

    if !active {
      return
    }

    store = [:]
    order = []

    let inner = ctx.utility!.fetcher!

    ctx.utility!.fetcher = { ctx2, url, fetchdef in
      try self.through(ctx2, url, fetchdef, inner)
    }
  }

  private func through(_ ctx: Context, _ url: String, _ fetchdef: VMap,
                       _ inner: FetcherFunc) throws -> Value {
    var method = "GET"
    if let m = fetchdef.entries["method"]?.asString, m != "" {
      method = m.uppercased()
    }

    let methods = foptStrList(options, "methods") ?? ["GET"]
    let cacheable = methods.contains { $0.uppercased() == method }
    if !cacheable {
      return try inner(ctx, url, fetchdef)
    }

    let key = method + " " + url
    let now = foptNow(options)()

    if let entry = store[key], entry.expiry > now {
      hit += 1
      return CacheFeature.replay(entry.snapshot)
    }

    var res: Value = .noval
    var err: Error? = nil
    do {
      res = try inner(ctx, url, fetchdef)
    } catch {
      err = error
    }

    if err == nil && CacheFeature.storable(res) {
      let snap = CacheFeature.snapshot(res)
      let ttl = foptInt(options, "ttl", 5000)
      evict()
      let entry = CacheEntry()
      entry.expiry = now + Int64(ttl)
      entry.snapshot = snap
      store[key] = entry
      order.append(key)
      miss += 1
      return CacheFeature.replay(snap)
    }

    bypass += 1
    if let err = err {
      throw err
    }
    return res
  }

  private static func storable(_ res: Value) -> Bool {
    let (status, has) = fresStatus(res)
    return has && status >= 200 && status < 300
  }

  private static func snapshot(_ res: Value) -> CacheSnapshot {
    let snap = CacheSnapshot()

    let (status, has) = fresStatus(res)
    if has {
      snap.status = status
    }
    if let rm = res.asMap {
      if let st = rm.entries["statusText"]?.asString {
        snap.statusText = st
      }
      if let f = rm.entries["json"]?.asNative as? NativeCall0 {
        snap.data = f()
      }
      if let headers = rm.entries["headers"]?.asMap {
        for (k, v) in headers.entries {
          snap.headers.entries[k.lowercased()] = v
        }
      }
    }

    return snap
  }

  // Replay builds a fresh transport-shaped response so the body stays
  // re-readable for every consumer.
  private static func replay(_ snap: CacheSnapshot) -> Value {
    let data = snap.data
    let headers = VMap()
    for (k, v) in snap.headers.entries {
      headers.entries[k] = v
    }
    let r = VMap()
    r.entries["status"] = .int(Int64(snap.status))
    r.entries["statusText"] = .string(snap.statusText)
    r.entries["body"] = .string("not-used")
    r.entries["json"] = .nat({ () -> Value in data } as NativeCall0)
    r.entries["headers"] = .map(headers)
    return .map(r)
  }

  // Evict drops oldest entries (FIFO) until the store is under `max`.
  private func evict() {
    let max = foptInt(options, "max", 256)
    while store.count >= max && order.count > 0 {
      let oldest = order.removeFirst()
      store.removeValue(forKey: oldest)
    }
  }
}
