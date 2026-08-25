// Univec SDK utility: fetcher - the default URLSession transport,
// mode/test blocking, and the injectable system.fetch override.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Non-following twin of URLSession.shared. The station feature's
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
  configuration: .default, delegate: ManualRedirectDelegate(), delegateQueue: nil)

func defaultHttpFetch(_ fullurl: String, _ fetchdef: VMap) throws -> Value {
  guard let url = URL(string: fullurl) else {
    let m = VMap()
    m.entries["status"] = .int(0)
    m.entries["statusText"] = .string("bad url")
    m.entries["headers"] = .map(VMap())
    m.entries["json"] = .nat({ () -> Value in .noval } as NativeCall0)
    m.entries["body"] = .string("")
    return .map(m)
  }

  var req = URLRequest(url: url)
  req.httpMethod = gp(fetchdef, "method").asString ?? "GET"

  if let body = gp(fetchdef, "body").asString, body != "" {
    req.httpBody = body.data(using: .utf8)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
  if !hasUA {
    req.setValue("Mozilla/5.0 (compatible; UnivecSDK/1.0)", forHTTPHeaderField: "User-Agent")
  }

  final class FetchBox: @unchecked Sendable {
    var data: Data?
    var resp: URLResponse?
    var err: Error?
  }
  let box = FetchBox()
  let sem = DispatchSemaphore(value: 0)
  let session = gp(fetchdef, "redirect").asString == "manual"
    ? manualRedirectSession : URLSession.shared
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
  if !bodyText.isEmpty {
    if let parsed = try? JSON.parse(bodyText) { jsonBody = parsed }
  }
  let captured = jsonBody

  let m = VMap()
  m.entries["status"] = .int(Int64(status))
  m.entries["statusText"] = .string(HTTPURLResponse.localizedString(forStatusCode: status))
  m.entries["headers"] = .map(resheaders)
  m.entries["json"] = .nat({ () -> Value in captured } as NativeCall0)
  m.entries["body"] = .string(bodyText)
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
