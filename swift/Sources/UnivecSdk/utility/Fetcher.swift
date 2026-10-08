// Univec SDK utility: fetcher - the default URLSession transport,
// mode/test blocking, and the injectable system.fetch override.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Cookies OFF on both sessions: the process-wide session carries the
// process-wide cookie storage, so one call's Set-Cookie would come back on
// the next, under a different credential. Pooling is per configuration and
// is unaffected.
private func cookielessConfiguration() -> URLSessionConfiguration {
  let cfg = URLSessionConfiguration.default
  cfg.httpCookieStorage = nil
  cfg.httpShouldSetCookies = false
  cfg.httpCookieAcceptPolicy = .never
  return cfg
}

private let defaultSession = URLSession(configuration: cookielessConfiguration())

// Non-following twin of defaultSession. The station feature's
// middleware sets `redirect: manual` on the fetch definition under a
// hosts egress policy: a 3xx must come back as a response like any
// other, because an automatic follow would carry injected credentials
// to a Location no policy approved (the ts donor's fetch honours the
// same key natively; redirect policy is per-delegate in URLSession,
// hence a second session).
private final class ManualRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private let manualRedirectSession = URLSession(
  configuration: cookielessConfiguration(),
  delegate: ManualRedirectDelegate(), delegateQueue: nil)

func defaultHttpFetch(_ fullurl: String, _ fetchdef: VMap) throws -> Value {
  // A request that cannot be sent fails the operation.
  guard let url = URL(string: fullurl) else {
    throw UnivecError("fetch_transport", "the URL could not be parsed", nil)
  }

  var req = URLRequest(url: url)
  req.httpMethod = gp(fetchdef, "method").asString ?? "GET"

  let body = gp(fetchdef, "body")
  if let text = body.asString, text != "" {
    req.httpBody = text.data(using: .utf8)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  } else if case .native(let ref) = body {
    if let data = ref.value as? Data {
      req.httpBody = data
    } else if let bytes = ref.value as? [UInt8] {
      req.httpBody = Data(bytes)
    }
  }

  var hasUA = false
  if let headers = gp(fetchdef, "headers").asMap {
    for (k, v) in headers.entries {
      if let sv = v.asString {
        if k.lowercased() == "user-agent" { hasUA = true }
        req.setValue(sv, forHTTPHeaderField: k)
      }
    }
  }
  // The default User-Agent is recorded with the headers the request sent.
  if !hasUA {
    let agent = "Mozilla/5.0 (compatible; UnivecSDK/1.0)"
    req.setValue(agent, forHTTPHeaderField: "User-Agent")
    if let sent = gp(fetchdef, "headers").asMap {
      sent.entries["user-agent"] = .string(agent)
    }
  }

  // Also per request, so no store reached another way can rewrite the
  // Cookie header set above — an `apiKey in: cookie` scheme sets one.
  req.httpShouldHandleCookies = false

  final class FetchBox: @unchecked Sendable {
    var data: Data?
    var resp: URLResponse?
    var err: Error?
  }
  let box = FetchBox()
  let sem = DispatchSemaphore(value: 0)
  let session = gp(fetchdef, "redirect").asString == "manual"
    ? manualRedirectSession : defaultSession
  let task = session.dataTask(with: req) { d, r, e in
    box.data = d; box.resp = r; box.err = e; sem.signal()
  }
  task.resume()
  sem.wait()

  if let e = box.err { throw e }

  let respData = box.data
  let http = box.resp as? HTTPURLResponse
  let status = http?.statusCode ?? 0
  let bodyText = respData.flatMap { String(data: $0, encoding: .utf8) } ?? ""

  let resheaders = VMap()
  if let http = http {
    for (k, v) in http.allHeaderFields {
      if let ks = k as? String {
        resheaders.entries[ks.lowercased()] = .string("\(v)")
      }
    }
  }

  var jsonBody: Value = .noval
  var unreadable = false
  if !bodyText.allSatisfy({ $0.isWhitespace }) {
    if let parsed = try? JSON.parse(bodyText) { jsonBody = parsed } else { unreadable = true }
  }
  let captured = jsonBody

  let m = VMap()
  m.entries["status"] = .int(Int64(status))
  m.entries["statusText"] = .string(HTTPURLResponse.localizedString(forStatusCode: status))
  m.entries["headers"] = .map(resheaders)
  m.entries["json"] = .nat({ () -> Value in captured } as NativeCall0)
  m.entries["body"] = .string(bodyText)
  m.entries["unreadable"] = .bool(unreadable)
  return .map(m)
}

func fetcherUtil(_ ctx: Context, _ fullurl: String, _ fetchdef: VMap) throws -> Value {
  if ctx.client!.mode != "live" {
    throw ctx.makeError("fetch_mode_block",
      "Request blocked by mode: \"\(ctx.client!.mode)\" (URL was: \"\(fullurl)\")")
  }

  let options = ctx.client!.optionsMap()
  if gpath(options, "feature", "test", "active") == .bool(true) {
    throw ctx.makeError("fetch_test_block",
      "Request blocked as test feature is active (URL was: \"\(fullurl)\")")
  }

  let sysFetch = gpath(options, "system", "fetch")
  if isNil(sysFetch) {
    return try defaultHttpFetch(fullurl, fetchdef)
  }

  if let fn = sysFetch.asNative as? SystemFetch {
    return fn(fullurl, fetchdef)
  }

  throw ctx.makeError("fetch_invalid", "system.fetch is not a valid function")
}
