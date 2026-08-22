// Univec SDK - core contracts.

import Foundation

// The minimal entity contract the pipeline depends on (list-wrapping in
// MakeResult, feature hooks). Concrete entity classes derive from
// UnivecEntityBase which implements this.
public protocol Entity: AnyObject {
  func getName() -> String
  func make() -> Entity
  @discardableResult func data(_ newdata: Value?) -> Value
  @discardableResult func matchv(_ newmatch: Value?) -> Value
}

public extension Entity {
  @discardableResult func data() -> Value { data(nil) }
  @discardableResult func matchv() -> Value { matchv(nil) }
}

// Transport function: performs the HTTP (or mock) request. Returns a
// transport-shaped response map (Value.map):
//   { status, statusText, headers, json: .nat(()->Value), body }
// Throws (typically UnivecError) on transport-level failure. A returned
// `.noval` mirrors the go pipeline's (nil, nil) "no response".
public typealias FetcherFunc = (Context, String, VMap) throws -> Value
