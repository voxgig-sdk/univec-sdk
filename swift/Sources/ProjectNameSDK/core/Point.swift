// Univec SDK - typed view over an endpoint (point) definition.

import Foundation

public final class Point {
  public var args: VMap
  public var rename: VMap
  public var method: String = ""
  public var orig: String = ""
  public var parts: VList = VList()
  public var params: VList? = nil
  public var select: VMap? = nil
  // Absent in config means ACTIVE: emission drops `active: true` as a
  // default (sdkgen L0), so only an explicit `active: false` turns a point off.
  public var active: Bool = true
  public var relations: VList? = nil
  public var alias: VMap = VMap()
  public var transform: VMap = VMap()

  public init(_ pointmap: VMap?) {
    args = VMap()
    args.entries["params"] = .list([])
    rename = VMap()
    rename.entries["params"] = .map(VMap())

    let pm: Value = pointmap == nil ? .noval : .map(pointmap!)
    if let am = getprop(pm, .string("args")).asMap { args = am }
    if let rm = getprop(pm, .string("rename")).asMap { rename = rm }
    if let m = getprop(pm, .string("method")).asString { method = m }
    if let o = getprop(pm, .string("orig")).asString { orig = o }
    if let pl = getprop(pm, .string("parts")).asList { parts = pl }
    if let pr = getprop(pm, .string("params")).asList { params = pr }
    if let sm = getprop(pm, .string("select")).asMap { select = sm }
    if let ab = getprop(pm, .string("active")).asBool { active = ab }
    if let rl = getprop(pm, .string("relations")).asList { relations = rl }
    if let al = getprop(pm, .string("alias")).asMap { alias = al }
    if let tf = getprop(pm, .string("transform")).asMap { transform = tf }
  }
}
