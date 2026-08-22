// Univec SDK - resolved operation definition.

import Foundation

public final class Operation {
  public var entity: String = "_"
  public var name: String = "_"
  public var input: String = "_"
  public var points: [VMap] = []
  public var alias: VMap? = nil

  public init(_ opmap: VMap) {
    let m: Value = .map(opmap)

    if let e = getprop(m, .string("entity")).asString, e != "" { entity = e }
    if let n = getprop(m, .string("name")).asString, n != "" { name = n }
    if let i = getprop(m, .string("input")).asString, i != "" { input = i }

    if let tlist = getprop(m, .string("points")).asList {
      for t in tlist.items {
        if let tm = t.asMap { points.append(tm) }
      }
    }

    if let am = getprop(m, .string("alias")).asMap { alias = am }
  }
}
