// Idempotency keys for mutating operations. Adds an `Idempotency-Key` header
// (name configurable via `header`) to unsafe requests so a server can
// de-duplicate retried writes. The key is set once, at PreRequest, before the
// request is built - so it is stable across transport-level retries of the
// same call. A caller-supplied header is never overwritten (case-insensitive).
// The key generator is injectable (`keygen`).

import Foundation

public final class IdempotencyFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?

  // Activity tracking (mirrors the ts client._idempotency record).
  public var issued = 0
  public var last = ""

  public override init() {
    super.init()
    version = "0.0.1"
    name = "idempotency"
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

    guard let spec = ctx.spec else {
      return
    }

    if !isMutating(ctx) {
      return
    }

    let header = foptStr(options, "header", "Idempotency-Key")

    // Respect a key the caller already provided.
    let (_, has) = fheaderGet(spec.headers, header)
    if has {
      return
    }

    let key = genkey()
    spec.headers.entries[header] = .string(key)

    issued += 1
    last = key
  }

  private func isMutating(_ ctx: Context) -> Bool {
    let methods = foptStrList(options, "methods") ?? ["POST", "PUT", "PATCH", "DELETE"]
    let method = ctx.spec?.method.uppercased() ?? ""
    if method != "" && methods.contains(where: { $0.uppercased() == method }) {
      return true
    }

    let opname = ctx.op?.name ?? ""
    let ops = foptStrList(options, "ops") ?? ["create", "update", "remove"]
    return ops.contains(opname)
  }

  private func genkey() -> String {
    if let keygen = gp(options, "keygen").asNative as? () -> String {
      return keygen()
    }
    let key = String(format: "%06x%06x%06x%06x",
      Int.random(in: 0..<0x1000000), Int.random(in: 0..<0x1000000),
      Int.random(in: 0..<0x1000000), Int.random(in: 0..<0x1000000))
    return String(key.prefix(24))
  }
}
