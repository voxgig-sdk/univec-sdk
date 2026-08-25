// Univec SDK - shared option readers for the feature implementations.
// Feature options arrive as a loose Value map; these helpers normalise access
// and supply defaults, mirroring the C# donor's FeatureOptions.

import Foundation

func fopt(_ options: VMap?, _ key: String) -> Value { gp(options, key) }

func foptBool(_ options: VMap?, _ key: String, _ def: Bool) -> Bool {
  gp(options, key).asBool ?? def
}

func foptInt(_ options: VMap?, _ key: String, _ def: Int) -> Int {
  switch gp(options, key) {
  case .int(let n): return Int(n)
  case .double(let d): return Int(d)
  default: return def
  }
}

func foptNum(_ options: VMap?, _ key: String, _ def: Double) -> Double {
  switch gp(options, key) {
  case .int(let n): return Double(n)
  case .double(let d): return d
  default: return def
  }
}

func foptStr(_ options: VMap?, _ key: String, _ def: String) -> String {
  if let s = gp(options, key).asString, s != "" { return s }
  return def
}

func foptMap(_ options: VMap?, _ key: String) -> VMap? { gp(options, key).asMap }

func foptList(_ options: VMap?, _ key: String) -> VList? { gp(options, key).asList }

func foptStrList(_ options: VMap?, _ key: String) -> [String]? {
  guard let l = gp(options, key).asList else { return nil }
  return l.items.compactMap { $0.asString }
}

// FoptSleep returns the injectable sleep (option "sleep": (Int) -> Void),
// defaulting to a real Thread.sleep.
func foptSleep(_ options: VMap?) -> (Int) -> Void {
  if let fn = gp(options, "sleep").asNative as? (Int) -> Void { return fn }
  return { ms in if ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000.0) } }
}

// FoptNow returns the injectable clock (option "now": () -> Int64, ms),
// defaulting to the wall clock.
func foptNow(_ options: VMap?) -> () -> Int64 {
  if let fn = gp(options, "now").asNative as? () -> Int64 { return fn }
  return { Int64(Date().timeIntervalSince1970 * 1000) }
}

// FheaderGet reads a header value case-insensitively.
func fheaderGet(_ headers: VMap?, _ name: String) -> (Value, Bool) {
  guard let headers = headers else { return (.noval, false) }
  for (k, v) in headers.entries {
    if k.caseInsensitiveCompare(name) == .orderedSame { return (v, true) }
  }
  return (.noval, false)
}

// FheaderSetDefault sets a header only when no case-insensitive variant exists.
func fheaderSetDefault(_ headers: VMap?, _ name: String, _ value: String) {
  guard let headers = headers else { return }
  let (_, has) = fheaderGet(headers, name)
  if has { return }
  headers.entries[name] = .string(value)
}

// FresStatus extracts the numeric status from a transport-shaped response.
func fresStatus(_ res: Value) -> (Int, Bool) {
  guard let rm = res.asMap, let raw = rm.entries["status"] else { return (0, false) }
  switch raw {
  case .int(let n): return (Int(n), true)
  case .double(let d): return (Int(d), true)
  default: return (0, false)
  }
}

// FresHeader reads a header from a transport-shaped response.
func fresHeader(_ res: Value, _ name: String) -> (String, Bool) {
  guard let rm = res.asMap, let headers = rm.entries["headers"]?.asMap else { return ("", false) }
  let (v, has) = fheaderGet(headers, name)
  if !has { return ("", false) }
  guard let str = v.asString else { return ("", false) }
  return (str, true)
}

// FparseInt parses a decimal string; def when unparseable.
func fparseInt(_ s: String, _ def: Int) -> Int {
  Int(s.trimmingCharacters(in: .whitespaces)) ?? def
}
