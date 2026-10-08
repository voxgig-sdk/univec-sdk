// Univec SDK utility: result shaping (status/error, headers, body) and
// request/response transforms; plus clean + done.

import Foundation

func resultBasicUtil(_ ctx: Context) -> Result {
  let response = ctx.response
  let result = ctx.result

  if let result = result, let response = response {
    result.status = response.status
    result.statusText = response.statusText

    if result.status >= 400 {
      let msg = "request: \(result.status): \(result.statusText)"
      if let e = result.err {
        result.err = ctx.makeError("request_status", errMessage(e) + ": " + msg)
      } else {
        result.err = ctx.makeError("request_status", msg)
      }
    } else if let re = response.err {
      result.err = re
    }
  }

  return result!
}

func resultBodyUtil(_ ctx: Context) -> Result {
  let response = ctx.response
  let result = ctx.result

  if let result = result {
    if let jf = response?.jsonFunc, let resp = response, !isNil(resp.body) {
      result.body = jf()
    }
    if let resp = response, resp.unreadable {
      let sent: Value = ctx.spec == nil ? .noval : .map(ctx.spec!.headers)
      result.err = Response.unreadableBody(
        ctx, result.status, .map(result.headers), resp.body, sent, result.err)
    }
  }

  return result!
}

func resultHeadersUtil(_ ctx: Context) -> Result {
  let response = ctx.response
  let result = ctx.result

  if let result = result {
    if let hm = response?.headers.asMap {
      result.headers = hm
    } else {
      result.headers = VMap()
    }
  }

  return result!
}

// `$action` selects the point (see makePointUtil); it is never an API field,
// so the body is a copy without it. The caller's map is left untouched.
private func stripAction(_ reqdata: Value) -> Value {
  return omitKeys(reqdata, ["$action"])
}

// A header, cookie or query argument travels where prepareHeadersUtil or
// prepareQueryUtil sends it, so the body is built from the request data
// without it, unless the point marks it as a field the body keeps.
private func routedArgNames(_ ctx: Context) -> [String] {
  return (callArgs(ctx, "header") + callArgs(ctx, "cookie") + callArgs(ctx, "query")).map { $0.name }
    .filter { !fieldArg(ctx, $0) }
}

private func fieldArg(_ ctx: Context, _ name: String) -> Bool {
  return ["header", "cookie", "query"].contains { kind in
    guard let defs = gpath(ctx.point, "args", kind).asList else { return false }
    return defs.items.contains { gp($0, "name").asString == name && gp($0, "field").asBool == true }
  }
}

private func omitKeys(_ reqdata: Value, _ names: [String]) -> Value {
  guard let src = reqdata.asMap, names.contains(where: { src.entries[$0] != nil }) else {
    return reqdata
  }
  let body = VMap()
  for (key, val) in src.entries where !names.contains(key) {
    body.entries[key] = val
  }
  return .map(body)
}

func transformRequestUtil(_ ctx: Context) -> Value {
  if let sp = ctx.spec { sp.step = "reqform" }

  let reqdata = omitKeys(.map(ctx.reqdata), routedArgNames(ctx))

  guard let tfm = gp(ctx.point, "transform").asMap else { return stripAction(reqdata) }
  let reqform = gp(tfm, "req")
  if isNil(reqform) { return stripAction(reqdata) }

  return stripAction(transform(.map(vm(("reqdata", reqdata))), reqform))
}

func transformResponseUtil(_ ctx: Context) -> Value {
  if let sp = ctx.spec { sp.step = "resform" }

  guard let result = ctx.result, result.ok else { return .noval }

  guard let tfm = gp(ctx.point, "transform").asMap else { return .noval }
  let resform = gp(tfm, "res")
  if isNil(resform) { return .noval }

  let dataMap = vm(
    ("ok", .bool(result.ok)),
    ("status", .int(Int64(result.status))),
    ("statusText", .string(result.statusText)),
    ("headers", .map(result.headers)),
    ("body", result.body),
    ("err", result.err == nil ? .noval : .nat(result.err!)),
    ("resdata", result.resdata),
    ("resmatch", result.resmatch == nil ? .noval : .map(result.resmatch!))
  )

  let resdata = transform(.map(dataMap), resform)
  result.resdata = resdata
  return resdata
}

// MARK: - clean

// Everything that leaves the pipeline passes through clean; inside it data
// stays raw, so a hook can still read the header it must add to. See
// docs/explanation/secret-redaction.md.

// The derived clean block, MUTABLE after makeOptions since features register
// values later. Carried as a native object under options.__derived__.clean,
// which JSON.stringify prints as "<function>" rather than as the registry.
// Nested in Utility, whose registry it is, so no entity type can collide
// with it.
extension Utility {
  public final class CleanConfig {
    public var active = true
    public var keys: [String] = []
    public var mask = "[redacted]"
    public var hint = 0
    public var min = 4

    // Requests on other threads clean while one registers, so the registry
    // is read and written under its own lock.
    private let lock = NSLock()
    private var registry: [String] = []

    public var values: [String] {
      get {
        lock.lock()
        defer { lock.unlock() }
        return registry
      }
      set {
        lock.lock()
        defer { lock.unlock() }
        registry = newValue
      }
    }

    public init() {}

    // The forms not yet registered are added, longest first, in one step.
    func register(_ forms: [String]) {
      lock.lock()
      defer { lock.unlock() }
      var changed = false
      for form in forms where form.count >= min && !registry.contains(form) {
        registry.append(form)
        changed = true
      }
      if changed {
        registry.sort { $0.count > $1.count }
      }
    }
  }
}

private let cleanMaxDepth = 32
private let cleanCircular = "[circular]"

// encodeURIComponent's unreserved set.
private let cleanUnreserved = CharacterSet(
  charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

private func cleanNormKey(_ key: String) -> String {
  return key.lowercased()
    .replacingOccurrences(of: "-", with: "")
    .replacingOccurrences(of: "_", with: "")
}

private func cleanSplit(_ v: Value) -> [String] {
  let text = v.asString ?? (isNil(v) ? "" : stringify(v))
  return text.split(separator: ",", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { $0 != "" }
}

func cleanSplitValues(_ v: Value) -> [String] {
  if let l = v.asList {
    return l.items.compactMap { $0.asString }
  }
  return cleanSplit(v)
}

private func cleanCount(_ v: Value, _ dflt: Int) -> Int {
  var n: Double
  switch v {
  case .int(let i): n = Double(i)
  case .double(let d): n = d
  case .string(let s):
    guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else { return dflt }
    n = d
  default: return dflt
  }
  n = n.rounded(.down)
  return n.isFinite && 0 <= n ? Int(n) : dflt
}

func makeCleanConfig(_ cleanopts: Value) -> Utility.CleanConfig {
  let opts = cleanopts.asMap ?? VMap()
  let cfg = Utility.CleanConfig()
  cfg.active = gp(opts, "active") != .bool(false)
  cfg.keys = cleanSplit(gp(opts, "keys")).map(cleanNormKey)
  cfg.values = []
  cfg.mask = gp(opts, "mask").asString ?? "[redacted]"
  cfg.hint = cleanCount(gp(opts, "hint"), 0)
  cfg.min = max(1, cleanCount(gp(opts, "min"), 4))
  return cfg
}

// A context without options (makeError accepts a bare one) still masks by
// the schema defaults.
func cleanConfigOf(_ ctx: Context) -> Utility.CleanConfig {
  if let cfg = gpath(ctx.options, "__derived__", "clean").asNative as? Utility.CleanConfig {
    return cfg
  }
  return makeCleanConfig(gp(SdkSchema.optspec, "clean"))
}

// The encoded forms a value travels in.
private func cleanForms(_ value: String) -> [String] {
  var out = [value]
  func add(_ s: String) {
    if s != "" && !out.contains(s) { out.append(s) }
  }
  add(Data(value.utf8).base64EncodedString())
  add(value.addingPercentEncoding(withAllowedCharacters: cleanUnreserved) ?? "")
  add(String(JSON.quoted(value).dropFirst().dropLast()))
  return out
}

func cleanAddUtil(_ ctx: Context, _ value: Value) {
  let cfg = cleanConfigOf(ctx)
  guard let s = value.asString, s.count >= cfg.min else { return }
  cfg.register(cleanForms(s))
}

// Every scalar under a sensitive name, at any depth and of any shape: a
// credential mistyped as a map or a number is still a credential.
func cleanAddSensitiveUtil(_ ctx: Context, _ val: Value) {
  var seen: [ObjectIdentifier] = []
  cleanAddSensitiveAt(ctx, val, false, 0, &seen)
}

private func cleanAddSensitiveAt(
  _ ctx: Context, _ val: Value, _ under: Bool, _ depth: Int, _ seen: inout [ObjectIdentifier]
) {
  if cleanMaxDepth <= depth { return }
  switch val {
  case .string(let s):
    if under { cleanAddUtil(ctx, .string(s)) }
  case .int(let i):
    if under { cleanAddUtil(ctx, .string(String(i))) }
  case .double(let d):
    if under { cleanAddUtil(ctx, .string(cleanNumberText(d))) }
  case .list(let l):
    if seen.contains(ObjectIdentifier(l)) { return }
    seen.append(ObjectIdentifier(l))
    for item in l.items {
      cleanAddSensitiveAt(ctx, item, under, depth + 1, &seen)
    }
  case .map(let m):
    if seen.contains(ObjectIdentifier(m)) { return }
    seen.append(ObjectIdentifier(m))
    for (k, item) in m.entries {
      cleanAddSensitiveAt(ctx, item, under || cleanKeyUtil(ctx, k), depth + 1, &seen)
    }
  default:
    return
  }
}

// A number's decimal text as JavaScript's String() writes it, for whole values.
private func cleanNumberText(_ d: Double) -> String {
  if d.rounded() == d && abs(d) < 9.0e15 {
    return String(Int64(d))
  }
  return String(d)
}

private func cleanMaskValue(_ cfg: Utility.CleanConfig, _ value: String) -> String {
  if 0 < cfg.hint && value.count > 2 * cfg.hint {
    return cfg.mask + String(value.suffix(cfg.hint))
  }
  return cfg.mask
}

private func cleanString(_ cfg: Utility.CleanConfig, _ text: String) -> String {
  var out = text
  for value in cfg.values where out.contains(value) {
    out = out.replacingOccurrences(of: value, with: cleanMaskValue(cfg, value))
  }
  return out
}

private func cleanSensitiveKey(_ cfg: Utility.CleanConfig, _ key: String?) -> Bool {
  guard let key = key else { return false }
  let nk = cleanNormKey(key)
  return cfg.keys.contains { nk.contains($0) }
}

// A masked plain-data copy: closures dropped, cycles cut, and nothing shared
// with the live value, whose spec must stay raw. A typed pipeline product
// carried as a native (a Spec, a Result, a feature record) reads through its
// stored properties, the way `dump` would; the context reads through its
// own record so its client, options and config never enter.
private func cleanSnapshot(
  _ cfg: Utility.CleanConfig, _ val: Value, _ key: String?, _ depth: Int,
  _ seen: inout [ObjectIdentifier]
) -> Value {
  switch val {
  case .noval, .null, .sentinel:
    return val
  case .string(let s):
    return .string(cleanSensitiveKey(cfg, key) ? cleanMaskValue(cfg, s) : cleanString(cfg, s))
  case .function:
    return .noval
  case .bool, .int, .double:
    return cleanSensitiveKey(cfg, key) ? .string(cfg.mask) : val
  case .native(let ref):
    if cleanMaxDepth <= depth || seen.contains(ObjectIdentifier(ref)) {
      return .string(cleanCircular)
    }
    if cleanSensitiveKey(cfg, key) {
      return .string(cfg.mask)
    }
    seen.append(ObjectIdentifier(ref))
    defer { seen.removeLast() }
    return cleanNative(cfg, ref.value, key, depth, &seen)
  case .list(let l):
    if cleanMaxDepth <= depth || seen.contains(ObjectIdentifier(l)) {
      return .string(cleanCircular)
    }
    if cleanSensitiveKey(cfg, key) {
      return .string(cfg.mask)
    }
    seen.append(ObjectIdentifier(l))
    defer { seen.removeLast() }
    let out = VList()
    for item in l.items {
      out.items.append(cleanSnapshot(cfg, item, nil, depth + 1, &seen))
    }
    return .list(out)
  case .map(let m):
    if cleanMaxDepth <= depth || seen.contains(ObjectIdentifier(m)) {
      return .string(cleanCircular)
    }
    if cleanSensitiveKey(cfg, key) {
      return .string(cfg.mask)
    }
    seen.append(ObjectIdentifier(m))
    defer { seen.removeLast() }
    let out = VMap()
    for (k, item) in m.entries {
      let v = cleanSnapshot(cfg, item, k, depth + 1, &seen)
      if !v.isNoval { out.entries[cleanName(cfg, out, k)] = v }
    }
    return .map(out)
  }
}

// A registered value used as a property name is masked like any other
// string; names that mask alike take a counter, so none is lost.
private func cleanName(_ cfg: Utility.CleanConfig, _ out: VMap, _ key: String) -> String {
  let name = cleanString(cfg, key)
  if name == key || out.entries[name] == nil {
    return name
  }
  var i = 1
  while out.entries[name + "#" + String(i)] != nil { i += 1 }
  return name + "#" + String(i)
}

private func cleanErrorRecord(
  _ cfg: Utility.CleanConfig, _ err: Error, _ depth: Int, _ seen: inout [ObjectIdentifier]
) -> Value {
  let out = VMap()
  out.entries["message"] = .string(cleanString(cfg, errMessage(err)))
  if let se = err as? UnivecError {
    out.entries["sdk"] = .string(se.sdk)
    out.entries["code"] = .string(cleanString(cfg, se.code))
    out.entries["status"] = .int(Int64(se.status))
    out.entries["result"] = cleanSnapshot(cfg, se.resultVal, "result", depth + 1, &seen)
    out.entries["spec"] = cleanSnapshot(cfg, se.specVal, "spec", depth + 1, &seen)
  }
  return .map(out)
}

// A native the loose model carries. The pipeline's own products are read
// through their stored properties; anything else (a closure, a foreign
// object) is dropped, as a function is.
private func cleanNative(
  _ cfg: Utility.CleanConfig, _ any: Any, _ key: String?, _ depth: Int,
  _ seen: inout [ObjectIdentifier]
) -> Value {
  if let v = any as? Value {
    return cleanSnapshot(cfg, v, key, depth, &seen)
  }
  if let m = any as? VMap {
    return cleanSnapshot(cfg, .map(m), key, depth, &seen)
  }
  if let l = any as? VList {
    return cleanSnapshot(cfg, .list(l), key, depth, &seen)
  }
  if let s = any as? String {
    return cleanSnapshot(cfg, .string(s), key, depth, &seen)
  }
  if let b = any as? Bool {
    return cleanSnapshot(cfg, .bool(b), key, depth, &seen)
  }
  if let i = any as? Int {
    return cleanSnapshot(cfg, .int(Int64(i)), key, depth, &seen)
  }
  if let i = any as? Int64 {
    return cleanSnapshot(cfg, .int(i), key, depth, &seen)
  }
  if let d = any as? Double {
    return cleanSnapshot(cfg, .double(d), key, depth, &seen)
  }
  if let err = any as? Error {
    return cleanErrorRecord(cfg, err, depth, &seen)
  }
  if let ctx = any as? Context {
    return cleanSnapshot(cfg, .map(ctx.rawRecord()), key, depth, &seen)
  }
  if let ent = any as? Entity {
    return .string(ent.getName())
  }
  if any is UnivecSDK {
    return .noval
  }

  let mirror = Mirror(reflecting: any)
  if mirror.displayStyle == .optional {
    guard let inner = mirror.children.first?.value else { return .null }
    return cleanNative(cfg, inner, key, depth, &seen)
  }
  if mirror.displayStyle == .collection || mirror.displayStyle == .set {
    let out = VList()
    for child in mirror.children {
      let v = cleanNative(cfg, child.value, nil, depth + 1, &seen)
      out.items.append(v)
    }
    return .list(out)
  }
  if mirror.displayStyle == .dictionary {
    // Sorted, so colliding masked names number the same way every run.
    var pairs: [(String, Any)] = []
    for child in mirror.children {
      let pair = Mirror(reflecting: child.value).children.map { $0.value }
      guard 2 == pair.count else { continue }
      pairs.append((String(describing: pair[0]), pair[1]))
    }
    let out = VMap()
    for (k, item) in pairs.sorted(by: { $0.0 < $1.0 }) {
      let v = cleanNative(cfg, item, k, depth + 1, &seen)
      if !v.isNoval { out.entries[cleanName(cfg, out, k)] = v }
    }
    return .map(out)
  }
  if mirror.displayStyle == .class || mirror.displayStyle == .struct {
    let out = VMap()
    for child in mirror.children {
      guard let label = child.label else { continue }
      let v = cleanNative(cfg, child.value, label, depth + 1, &seen)
      if !v.isNoval { out.entries[label] = v }
    }
    return .map(out)
  }
  return .noval
}

// The SDK's own error is cleaned in place, since it is about to be thrown.
func cleanUtil(_ ctx: Context, _ val: Value) -> Value {
  let cfg = cleanConfigOf(ctx)

  if !cfg.active {
    return val
  }

  if let s = val.asString {
    return .string(cleanString(cfg, s))
  }

  if let err = val.asNative as? UnivecError {
    var seen: [ObjectIdentifier] = []
    err.message = cleanString(cfg, err.message)
    err.code = cleanString(cfg, err.code)
    if !isNil(err.resultVal) {
      err.resultVal = cleanSnapshot(cfg, err.resultVal, "result", 1, &seen)
    }
    if !isNil(err.specVal) {
      err.specVal = cleanSnapshot(cfg, err.specVal, "spec", 1, &seen)
    }
    return val
  }

  if val.asNative is Error {
    return val
  }

  var seen: [ObjectIdentifier] = []
  return cleanSnapshot(cfg, val, nil, 0, &seen)
}

func cleanKeyUtil(_ ctx: Context, _ key: String) -> Bool {
  return cleanSensitiveKey(cleanConfigOf(ctx), key)
}

func doneUtil(_ ctx: Context) throws -> Value {
  if let explain = ctx.ctrl.explain {
    // Refilled in place: the caller holds this very map (the Context took it
    // out of the ctrl map), so a replacement would leave them reading the
    // raw one.
    if let cleaned = cleanUtil(ctx, .map(explain)).asMap, cleaned !== explain {
      explain.entries = cleaned.entries
    }
    if let rm = explain.entries["result"]?.asMap {
      rm.entries.removeValue(forKey: "err")
    }
  }

  if let result = ctx.result, result.ok {
    return result.resdata
  }

  return try makeErrorUtil(ctx, nil)
}
