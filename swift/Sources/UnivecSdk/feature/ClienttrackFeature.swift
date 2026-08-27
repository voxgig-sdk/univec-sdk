// Client tracking. Establishes a stable per-client session id at
// construction and stamps identifying headers on every request: a
// `User-Agent` (`<clientName>/<clientVersion>`), an `X-Client-Id` (session),
// and a fresh per-request `X-Request-Id`. This lets a server correlate all
// traffic from one SDK instance and each individual call. Header names,
// client name/version and the id generator (`idgen`) are configurable;
// caller-provided User-Agent / X-Client-Id values are never clobbered.

import Foundation

public final class ClienttrackFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?

  // Activity tracking (mirrors the ts client._clienttrack record).
  public var session = ""
  public var requests = 0
  public var lastRequestID = ""
  public var clientName = ""

  public override init() {
    super.init()
    version = "0.0.1"
    name = "clienttrack"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)
    requests = 0
  }

  public override func postConstruct(_ ctx: Context) {
    if !active {
      return
    }
    session = foptStr(options, "sessionId", genid("session"))
    clientName = nameVersion()
  }

  public override func preRequest(_ ctx: Context) {
    if !active {
      return
    }

    guard let spec = ctx.spec else {
      return
    }

    // Lazily establish the session when postConstruct never fired.
    if session == "" {
      session = foptStr(options, "sessionId", genid("session"))
    }

    let h = foptMap(options, "headers")
    requests += 1
    let requestId = genid("request")

    fheaderSetDefault(spec.headers, foptStr(h, "agent", "User-Agent"), nameVersion())
    fheaderSetDefault(spec.headers, foptStr(h, "client", "X-Client-Id"), session)
    spec.headers.entries[foptStr(h, "request", "X-Request-Id")] = .string(requestId)

    lastRequestID = requestId
    clientName = nameVersion()
  }

  private func nameVersion() -> String {
    let name = foptStr(options, "clientName", "Univec-SDK")
    let version = foptStr(options, "clientVersion", "0.0.1")
    return name + "/" + version
  }

  private func genid(_ kind: String) -> String {
    if let idgen = gp(options, "idgen").asNative as? (String) -> String {
      return idgen(kind)
    }
    let prefix = String(kind.prefix(1))
    let hex = hex6(Int.random(in: 0..<0x1000000))
      + hex6(Int.random(in: 0..<0x1000000))
      + hex6(Int.random(in: 0..<0x1000000))
    var id = prefix + "-" + hex
    if id.count > 20 {
      id = String(id.prefix(20))
    }
    return id
  }

  private func hex6(_ n: Int) -> String {
    var s = String(n, radix: 16)
    while s.count < 6 { s = "0" + s }
    return s
  }
}
