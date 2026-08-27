// Per-request timeout. Wraps the active transport and races each attempt
// against a deadline; if the deadline wins, the request resolves to a
// `timeout` error instead of hanging. The inner transport is left to finish
// on its own background queue (its result is discarded), matching how the ts
// feature lets the losing racer resolve unobserved.

import Foundation

public final class TimeoutFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?

  // Activity tracking (mirrors the ts client._timeout record).
  public var count = 0
  public var ms = 0

  public override init() {
    super.init()
    version = "0.0.1"
    name = "timeout"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)

    if !active {
      return
    }

    let inner = ctx.utility!.fetcher!

    ctx.utility!.fetcher = { ctx2, url, fetchdef in
      try self.withTimeout(ctx2, url, fetchdef, inner)
    }
  }

  // Captures the inner transport's outcome from the background queue. Marked
  // @unchecked Sendable because the losing racer may still be writing when the
  // deadline wins - that write is intentionally discarded.
  private final class Box: @unchecked Sendable {
    var result: Value = .noval
    var err: Error? = nil
  }

  private func withTimeout(_ ctx: Context, _ url: String, _ fetchdef: VMap,
                           _ inner: @escaping FetcherFunc) throws -> Value {
    let msLimit = foptInt(options, "ms", 30000)
    if msLimit <= 0 {
      return try inner(ctx, url, fetchdef)
    }

    let box = Box()
    let sem = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      do {
        box.result = try inner(ctx, url, fetchdef)
      } catch {
        box.err = error
      }
      sem.signal()
    }

    if sem.wait(timeout: .now() + .milliseconds(msLimit)) == .timedOut {
      track(msLimit)
      throw ctx.makeError("timeout", "Request exceeded timeout of \(msLimit)ms")
    }

    // Unwraps any inner exception.
    if let err = box.err {
      throw err
    }
    return box.result
  }

  private func track(_ msLimit: Int) {
    count += 1
    ms = msLimit
  }
}
