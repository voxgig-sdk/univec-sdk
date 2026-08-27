// Automatic retry of transient failures with exponential backoff and
// jitter. Wraps the active transport so a single operation call may make
// several HTTP attempts. A failure is retryable when the transport throws,
// returns no value, or responds with a status in `statuses`
// (default: 408, 425, 429, 500, 502, 503, 504). An HTTP 429/503 with a
// `Retry-After` header overrides the computed backoff.

import Foundation

public final class RetryFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?

  // Activity tracking (mirrors the ts client._retry record).
  public var attempts = 0
  public var retries: [VMap] = []

  public override init() {
    super.init()
    version = "0.0.1"
    name = "retry"
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
      try self.withRetry(ctx2, url, fetchdef, inner)
    }
  }

  private func withRetry(_ ctx: Context, _ url: String, _ fetchdef: VMap,
                         _ inner: FetcherFunc) throws -> Value {
    let max = foptInt(options, "retries", 2)
    let minDelay = foptInt(options, "minDelay", 50)
    let maxDelay = foptInt(options, "maxDelay", 2000)
    let factor = foptNum(options, "factor", 2)

    var attempt = 0

    while true {
      var res: Value = .noval
      var err: Error? = nil
      do {
        res = try inner(ctx, url, fetchdef)
      } catch {
        err = error
      }

      if !retryable(res, err) || attempt >= max {
        // Out of attempts (or not retryable): return the last response as-is
        // (or rethrow) to preserve pipeline semantics.
        if let err = err {
          throw err
        }
        return res
      }

      let wait = backoff(res, attempt, minDelay, maxDelay, factor)
      track(attempt + 1, res, err, wait)
      sleepMs(wait)
      attempt += 1
    }
  }

  private func retryable(_ res: Value, _ err: Error?) -> Bool {
    if err != nil {
      return true
    }
    if isNil(res) {
      return true
    }
    let (status, has) = fresStatus(res)
    if !has {
      return false
    }
    let statuses: [Int]
    if let list = foptList(options, "statuses") {
      statuses = list.items.map { toInt($0) }
    } else {
      statuses = [408, 425, 429, 500, 502, 503, 504]
    }
    for s in statuses {
      if s == status {
        return true
      }
    }
    return false
  }

  private func backoff(_ res: Value, _ attempt: Int, _ minDelay: Int, _ maxDelay: Int,
                       _ factor: Double) -> Int {
    // Honour a server-provided Retry-After (seconds) when present.
    let (ra, has) = retryAfter(res)
    if has {
      return ra > maxDelay ? maxDelay : ra
    }
    let baseWait = Double(minDelay) * pow(factor, Double(attempt))
    var jitter = 0
    if foptBool(options, "jitter", true) && minDelay > 0 {
      jitter = Int.random(in: 0..<minDelay)
    }
    let wait = Int(baseWait) + jitter
    return wait > maxDelay ? maxDelay : wait
  }

  private func retryAfter(_ res: Value) -> (Int, Bool) {
    let (v, has) = fresHeader(res, "retry-after")
    if !has {
      return (0, false)
    }
    let seconds = fparseInt(v, -1)
    if seconds < 0 {
      return (0, false)
    }
    return (seconds * 1000, true)
  }

  private func sleepMs(_ ms: Int) {
    if ms <= 0 {
      return
    }
    foptSleep(options)(ms)
  }

  private func track(_ attempt: Int, _ res: Value, _ err: Error?, _ wait: Int) {
    attempts += 1

    let entry = VMap()
    entry.entries["attempt"] = .int(Int64(attempt))
    entry.entries["wait"] = .int(Int64(wait))
    let (status, has) = fresStatus(res)
    if has {
      entry.entries["status"] = .int(Int64(status))
    }
    if let err = err {
      entry.entries["error"] = .string(errMessage(err))
    }
    retries.append(entry)
  }
}
