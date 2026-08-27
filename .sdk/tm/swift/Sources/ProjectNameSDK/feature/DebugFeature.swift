// Request/response capture for debugging. Records a bounded ring buffer of
// per-operation traces - method, URL, redacted headers, response status and
// timing - on the feature's entries. Sensitive header values (matching
// `redact`, default authorization/cookie/api-key style names) are masked.
// An optional `onEntry` callback receives each finished entry (e.g. to
// stream to a console). `max` caps the buffer (default 100).

import Foundation

public final class DebugFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?

  // Activity tracking (mirrors the ts client._debug record).
  public var entries: [VMap] = []

  private static let entryKey = "debug_entry"

  private static let defaultRedact: [String] = [
    "authorization", "cookie", "set-cookie", "api-key", "apikey",
    "x-api-key", "idempotency-key",
  ]

  public override init() {
    super.init()
    version = "0.0.1"
    name = "debug"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)
  }

  public override func preRequest(_ ctx: Context) {
    if !active {
      return
    }

    let entity = ctx.op?.entity ?? "_"
    let opname = ctx.op?.name ?? "_"

    let entry = VMap()
    entry.entries["op"] = .string(entity + "." + opname)
    entry.entries["start"] = .int(foptNow(options)())
    if let spec = ctx.spec {
      entry.entries["method"] = .string(spec.method)
      entry.entries["url"] = .string(spec.url != "" ? spec.url : spec.path)
      entry.entries["headers"] = .map(redact(spec.headers))
    }
    ctx.out[DebugFeature.entryKey] = entry
  }

  public override func preResponse(_ ctx: Context) {
    if !active {
      return
    }

    guard let entry = ctx.out[DebugFeature.entryKey] as? VMap else {
      return
    }
    if let response = ctx.response {
      entry.entries["status"] = .int(Int64(response.status))
      let curUrl = gp(entry, "url").asString ?? ""
      if curUrl == "", let spec = ctx.spec {
        entry.entries["url"] = .string(spec.url)
      }
    }
  }

  public override func preDone(_ ctx: Context) {
    finish(ctx, true)
  }

  public override func preUnexpected(_ ctx: Context) {
    if let entry = ctx.out[DebugFeature.entryKey] as? VMap, let err = ctx.ctrl.err {
      entry.entries["error"] = .string(errMessage(err))
    }
    finish(ctx, false)
  }

  private func finish(_ ctx: Context, _ ok: Bool) {
    // Finish once per operation: the marker in ctx.out is consumed here.
    guard let entry = ctx.out[DebugFeature.entryKey] as? VMap else {
      return
    }
    ctx.out.removeValue(forKey: DebugFeature.entryKey)

    entry.entries["ok"] = .bool(ok && (ctx.result == nil || ctx.result!.ok))
    let sv = gp(entry, "start")
    let start: Int64 = isNil(sv) ? 0 : toLong(sv)
    var dur = foptNow(options)() - start
    if dur < 0 {
      dur = 0
    }
    entry.entries["durationMs"] = .int(dur)
    if isNil(gp(entry, "status")), let result = ctx.result {
      entry.entries["status"] = .int(Int64(result.status))
    }

    entries.append(entry)
    let max = foptInt(options, "max", 100)
    while entries.count > max {
      entries.removeFirst()
    }

    if let onEntry = gp(options, "onEntry").asNative as? (VMap) -> Void {
      onEntry(entry)
    }
  }

  private func redact(_ headers: VMap?) -> VMap {
    let redacted = VMap()
    guard let headers = headers else {
      return redacted
    }
    let patterns = foptStrList(options, "redact") ?? DebugFeature.defaultRedact
    for (k, v) in headers.entries {
      let masked = patterns.contains(k.lowercased())
      redacted.entries[k] = masked ? .string("<redacted>") : v
    }
    return redacted
  }
}
