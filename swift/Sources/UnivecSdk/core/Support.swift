// Univec SDK - shared value helpers for the loose object model.
//
// The SDK, like its Voxgig-Struct data model, carries loose JSON-shaped data
// as `Value` (see Struct/Value.swift): maps are `VMap`, lists are `VList`,
// scalars are `.string/.int/.double/.bool`, absent/null is `.noval/.null`,
// and language-runtime callables/objects the model must transport are
// `.native`. Typed pipeline products (Context, Spec, Result, ...) are plain
// classes. These helpers mirror the C# donor's Helpers + the struct accessors.

import Foundation

// A callable stored in the loose model (the transport `json` thunk, feature
// callbacks, system.fetch). `.nat(closure)` wraps it; `callNative` unwraps.
public typealias NativeCall0 = () -> Value

// UnsupportedOp is thrown by entity base methods for operations the API spec
// does not define.
func unsupportedOp(_ opname: String, _ entityname: String) -> UnivecError {
  return UnivecError(
    "unsupported_op",
    "operation '\(opname)' not supported by entity '\(entityname)'", nil)
}

// errMessage extracts a human message from any Error (SDK errors carry one).
func errMessage(_ e: Error) -> String {
  if let se = e as? UnivecError { return se.message }
  return String(describing: e)
}

func toInt(_ v: Value) -> Int {
  switch v {
  case .int(let n): return Int(n)
  case .double(let d): return Int(d)
  default: return -1
  }
}

func toLong(_ v: Value) -> Int64 {
  switch v {
  case .int(let n): return n
  case .double(let d): return Int64(d)
  default: return -1
  }
}

// asVMap / asVList unwrap a Value node to its reference container.
func asVMap(_ v: Value) -> VMap? { v.asMap }
func asVList(_ v: Value) -> VList? { v.asList }

// mapv builds a Value map (.map) from pairs, preserving insertion order.
func mapv(_ pairs: (String, Value)...) -> Value { .map(pairs) }

// vm builds a VMap from pairs.
func vm(_ pairs: (String, Value)...) -> VMap {
  let m = VMap()
  for (k, v) in pairs { m.entries[k] = v }
  return m
}

// listv builds a Value list (.list) from items.
func listv(_ items: Value...) -> Value { .list(items) }

// s/i/d/b: terse Value scalar constructors.
func s(_ v: String) -> Value { .string(v) }

// isNil: absent or JSON null (the SDK treats both as "no value").
func isNil(_ v: Value) -> Bool { v.isNoval || v.isNull }

// nativeClosure0 pulls a stored no-arg thunk (the transport `json` function).
func nativeClosure0(_ v: Value) -> NativeCall0? { v.asNative as? NativeCall0 }

// jtp is the SDK path-list constructor (C# StructUtils.Jt): a Value list of
// string path segments for getpath/setpath.
func jtp(_ segs: String...) -> Value { .list(segs.map { .string($0) }) }
func jtpv(_ segs: [String]) -> Value { .list(segs.map { .string($0) }) }

// gp: Group-A property read (C# StructUtils.GetProp) over an optional VMap or
// an arbitrary Value.
func gp(_ m: VMap?, _ key: String) -> Value { getprop(m == nil ? .noval : .map(m!), .string(key)) }
func gp(_ v: Value, _ key: String) -> Value { getprop(v, .string(key)) }

// gpath: getpath over an optional VMap store (C# StructUtils.GetPath(m, Jt(...))).
func gpath(_ m: VMap?, _ segs: String...) -> Value {
  getpath(m == nil ? .noval : .map(m!), jtpv(segs))
}
func gpath(_ v: Value, _ segs: String...) -> Value { getpath(v, jtpv(segs)) }

// regexReplace replaces every match of `pattern` in `input` with the literal
// `replacement` (template metacharacters in the replacement are escaped).
func regexReplace(_ input: String, _ pattern: String, _ replacement: String) -> String {
  guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
  let range = NSRange(input.startIndex..., in: input)
  let tmpl = NSRegularExpression.escapedTemplate(for: replacement)
  return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: tmpl)
}

// The injectable system.fetch signature (options.system.fetch).
public typealias SystemFetch = (String, VMap) -> Value
