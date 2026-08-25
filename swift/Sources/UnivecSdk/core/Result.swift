// Univec SDK - operation result.

import Foundation

public final class Result {
  public var ok: Bool = false
  public var status: Int = -1
  public var statusText: String = ""
  public var headers: VMap = VMap()
  public var body: Value = .noval
  public var err: Error? = nil
  public var resdata: Value = .noval
  public var resmatch: VMap? = nil

  // Feature extensions: pagination signals (paging feature) and the
  // incremental item iterator (streaming feature).
  public var paging: VMap? = nil
  public var streaming: Bool = false
  public var stream: (() -> [Value])? = nil

  public init(_ resmap: VMap?) {
    let m: Value = resmap == nil ? .map(VMap()) : .map(resmap!)

    if let b = getprop(m, .string("ok")).asBool { ok = b }

    let st = getprop(m, .string("status"))
    if !isNil(st) { status = toInt(st) }

    if let s = getprop(m, .string("statusText")).asString { statusText = s }

    if let hm = getprop(m, .string("headers")).asMap { headers = hm }

    body = getprop(m, .string("body"))

    if let e = getprop(m, .string("err")).asNative as? Error { err = e }

    resdata = getprop(m, .string("resdata"))

    if let rmm = getprop(m, .string("resmatch")).asMap { resmatch = rmm }
  }
}
