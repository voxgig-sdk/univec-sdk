// Outbound HTTP(S) proxy support. Wraps the active transport and annotates
// each request's fetch definition with the proxy target (`fetchdef.proxy`).
// The default transport honours the annotation by routing the request through
// the named proxy; custom transports can do the same. The proxy target comes
// from options (`url`) or, when `fromEnv` is set, the standard HTTPS_PROXY /
// HTTP_PROXY / NO_PROXY environment variables. Hosts matching `noProxy` bypass
// the proxy.

import Foundation

public final class ProxyFeature: BaseFeature {
  private var client: UnivecSDK?
  private var options: VMap?
  private var noProxy: [String] = []

  // Activity tracking (mirrors the ts client._proxy record).
  public var routed = 0
  public var url = ""

  private static let hostRe = try! NSRegularExpression(
    pattern: "^[a-z]+://([^/:]+)", options: [.caseInsensitive])

  public override init() {
    super.init()
    version = "0.0.1"
    name = "proxy"
    active = true
  }

  public override func initFeature(_ ctx: Context, _ options: VMap) {
    client = ctx.client
    self.options = options
    active = foptBool(options, "active", false)

    if !active {
      return
    }

    url = foptStr(options, "url", "")
    var noProxyList = foptStrList(options, "noProxy")

    if foptBool(options, "fromEnv", false) {
      if url == "" {
        url = firstEnv("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy")
      }
      if noProxyList == nil {
        let np = firstEnv("NO_PROXY", "no_proxy")
        if np != "" {
          noProxyList = np.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        }
      }
    }

    noProxy = []
    for raw in noProxyList ?? [] {
      let np = raw.trimmingCharacters(in: .whitespaces)
      if np != "" {
        noProxy.append(np)
      }
    }

    let inner = ctx.utility!.fetcher!

    ctx.utility!.fetcher = { ctx2, url, fetchdef in
      let routedDef = self.route(url, fetchdef)
      return try inner(ctx2, url, routedDef)
    }
  }

  private func route(_ requestUrl: String, _ fetchdef: VMap) -> VMap {
    if url == "" || bypass(requestUrl) {
      return fetchdef
    }

    let routedDef = VMap()
    for (k, v) in fetchdef.entries {
      routedDef.entries[k] = v
    }
    routedDef.entries["proxy"] = .string(url)

    routed += 1
    return routedDef
  }

  private func bypass(_ requestUrl: String) -> Bool {
    if noProxy.isEmpty {
      return false
    }
    var host = requestUrl
    if let h = extractHost(requestUrl) {
      host = h
    }
    for np in noProxy {
      if np == "*" {
        return true
      }
      let bare = String(np.drop(while: { $0 == "." }))
      if host == np || host.hasSuffix("." + bare) {
        return true
      }
    }
    return false
  }

  private func extractHost(_ requestUrl: String) -> String? {
    let range = NSRange(requestUrl.startIndex..., in: requestUrl)
    guard let m = ProxyFeature.hostRe.firstMatch(in: requestUrl, options: [], range: range),
      m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: requestUrl) else {
      return nil
    }
    return String(requestUrl[r])
  }

  private func firstEnv(_ names: String...) -> String {
    for name in names {
      if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
        return v
      }
    }
    return ""
  }
}
