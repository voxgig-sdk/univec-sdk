// Univec SDK - transport response wrapper.

import Foundation

public final class Response {
  public var status: Int = -1
  public var statusText: String = ""
  public var headers: Value = .noval
  public var jsonFunc: NativeCall0? = nil
  public var body: Value = .noval
  public var err: Error? = nil

  public init(_ resmap: VMap?) {
    let m: Value = resmap == nil ? .map(VMap()) : .map(resmap!)

    let st = getprop(m, .string("status"))
    if !isNil(st) { status = toInt(st) }

    if let s = getprop(m, .string("statusText")).asString { statusText = s }

    headers = getprop(m, .string("headers"))

    if let jf = getprop(m, .string("json")).asNative as? NativeCall0 { jsonFunc = jf }

    body = getprop(m, .string("body"))

    if let e = getprop(m, .string("err")).asNative as? Error { err = e }
  }
}
