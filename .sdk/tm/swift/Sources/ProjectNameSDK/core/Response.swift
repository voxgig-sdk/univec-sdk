// Univec SDK - transport response wrapper.

import Foundation

public final class Response {
  public var status: Int = -1
  public var statusText: String = ""
  public var headers: Value = .noval
  public var jsonFunc: NativeCall0? = nil
  public var body: Value = .noval
  public var err: Error? = nil
  // Set by a transport that could not read a non-blank body as JSON.
  public var unreadable: Bool = false

  private static let previewLength = 160

  public init(_ resmap: VMap?) {
    let m: Value = resmap == nil ? .map(VMap()) : .map(resmap!)

    let st = getprop(m, .string("status"))
    if !isNil(st) { status = toInt(st) }

    if let s = getprop(m, .string("statusText")).asString { statusText = s }

    headers = getprop(m, .string("headers"))

    if let jf = getprop(m, .string("json")).asNative as? NativeCall0 { jsonFunc = jf }

    body = getprop(m, .string("body"))

    if let e = getprop(m, .string("err")).asNative as? Error { err = e }

    unreadable = getprop(m, .string("unreadable")) == .bool(true)
  }

  // A body that is not JSON. An HTTP failure keeps its own error, with the
  // response described; otherwise the code tells a wrong content type from
  // malformed JSON.
  static func unreadableBody(
    _ ctx: Context, _ status: Int, _ headers: Value, _ text: Value, _ sent: Value, _ failed: Error?
  ) -> Error {
    let type = headerValue(headers, "content-type")
    let agent = clean(ctx, headerValue(sent, "user-agent"))
    var detail = "HTTP \(status), content-type " + (type.isEmpty ? "none" : type)
      + ", user-agent " + (agent.isEmpty ? "transport default" : agent)
    if !isNil(text) {
      detail += ", body: " + preview(ctx, text)
    }

    if let sdkErr = failed as? UnivecError {
      sdkErr.message += " (\(detail))"
      return sdkErr
    }
    if let other = failed {
      return ctx.makeError("", "\(other) (\(detail))")
    }
    if type.isEmpty || type.lowercased().contains("json") {
      return ctx.makeError("response_json_invalid", "response: body is not valid JSON (\(detail))")
    }
    return ctx.makeError("response_content_type", "response: expected JSON, got \(type) (\(detail))")
  }

  private static func headerValue(_ headers: Value, _ name: String) -> String {
    guard let hm = headers.asMap else { return "" }
    for (k, v) in hm.entries where k.lowercased() == name {
      return v.asString ?? stringify(v)
    }
    return ""
  }

  private static func clean(_ ctx: Context, _ s: String) -> String {
    guard let u = ctx.utility, let c = u.clean else { return s }
    return c(ctx, .string(s)).asString ?? s
  }

  // Cleaned whole: a secret the bound would split could leave its prefix.
  private static func preview(_ ctx: Context, _ text: Value) -> String {
    let raw = text.asString ?? stringify(text)
    let flat = clean(ctx, raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
    let scalars = flat.unicodeScalars
    if scalars.count <= previewLength { return flat }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars.prefix(previewLength))
    return String(out) + "..."
  }
}
