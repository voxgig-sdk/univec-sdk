// Univec SDK - HTTP request specification.

import Foundation

public final class Spec {
  public var parts: VList? = nil
  public var headers: VMap = VMap()
  public var alias: VMap = VMap()
  public var base: String = ""
  public var prefix: String = ""
  public var suffix: String = ""
  public var params: VMap = VMap()
  public var query: VMap = VMap()
  public var step: String = ""
  public var method: String = "GET"
  public var body: Value = .noval
  public var url: String = ""
  public var path: String = ""

  public init(_ specmap: VMap?) {
    guard let m = specmap else { return }
    if let v = m.entries["parts"], let parts = v.asList { self.parts = parts }
    if let v = m.entries["headers"], let h = v.asMap { self.headers = h }
    if let v = m.entries["alias"], let a = v.asMap { self.alias = a }
    if let v = m.entries["base"], let b = v.asString { self.base = b }
    if let v = m.entries["prefix"], let p = v.asString { self.prefix = p }
    if let v = m.entries["suffix"], let sf = v.asString { self.suffix = sf }
    if let v = m.entries["params"], let pm = v.asMap { self.params = pm }
    if let v = m.entries["query"], let q = v.asMap { self.query = q }
    if let v = m.entries["step"], let st = v.asString { self.step = st }
    if let v = m.entries["method"], let mm = v.asString { self.method = mm }
    if let v = m.entries["body"] { self.body = v }
    if let v = m.entries["url"], let u = v.asString { self.url = u }
    if let v = m.entries["path"], let pa = v.asString { self.path = pa }
  }
}
