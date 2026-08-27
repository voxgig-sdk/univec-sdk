// Streaming result support. For list-style operations it attaches a
// `result.stream` function yielding items so callers can consume them
// incrementally with `for item in result.stream!()` instead of materialising
// the whole list at once. A `chunkSize` groups items into `.list` batches
// when set; a `chunkDelay` (ms) paces delivery via the injectable `sleep`
// for offline tests.

import Foundation

public final class StreamingFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?

  // Activity tracking (mirrors the ts client._streaming record).
  public var opened = 0

  public override init() {
    super.init()
    version = "0.0.1"
    name = "streaming"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)
  }

  public override func preResult(_ ctx: Context) {
    if !active || !streamable(ctx) {
      return
    }
    guard let result = ctx.result else {
      return
    }

    result.streaming = true
    result.stream = { self.iterate(result) }

    opened += 1
  }

  private func iterate(_ result: Result) -> [Value] {
    let chunkDelay = foptInt(options, "chunkDelay", 0)
    let chunkSize = foptInt(options, "chunkSize", 0)
    let sleep = foptSleep(options)

    // Read lazily at stream() call time so downstream result processing
    // is reflected.
    let items = result.resdata.asList?.items ?? []

    var out: [Value] = []

    if chunkSize > 0 {
      var i = 0
      while i < items.count {
        if chunkDelay > 0 {
          sleep(chunkDelay)
        }
        let end = min(i + chunkSize, items.count)
        out.append(.list(Array(items[i..<end])))
        i += chunkSize
      }
      return out
    }

    for item in items {
      if chunkDelay > 0 {
        sleep(chunkDelay)
      }
      out.append(item)
    }
    return out
  }

  private func streamable(_ ctx: Context) -> Bool {
    let opname = ctx.op?.name ?? ""
    let ops = foptStrList(options, "ops") ?? ["list"]
    return ops.contains(opname)
  }
}
