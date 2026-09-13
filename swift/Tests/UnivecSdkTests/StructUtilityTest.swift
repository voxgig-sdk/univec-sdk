// Drives the shared struct corpus (../../../.sdk/test/test.json, root key
// "struct") against the vendored struct utility THROUGH the vendored omni
// runner (OmniResolver over Tests/vendor/omni) - the engine half of the
// hand-written runner this file used to carry. Mirrors
// tm/csharp/test/StructUtilityTest.cs and tm/go/test/struct_utility_test.go.
//
// What changed with the migration, and why each change is load-bearing:
//
//   - A missing or EMPTY category/section now FAILS. The retired inline
//     engine returned early whenever a section did not resolve to a list,
//     so `testSentinels` drove a category called "sentinels" that the
//     corpus renamed to "nullsem" LONG AGO and reported PASS over zero
//     assertions for every one of its 33 entries.
//
//   - `err:` entries now RUN. The retired engine skipped every entry
//     carrying one ("not yet wired uniformly"), which silently dropped 55
//     cases - all of validate.invalid and transform.apply among them.
//     Struct's Swift port COLLECTS diagnostics in `Injection.errs` instead
//     of raising (unlike the C#/TS ports, which throw), so the validate and
//     transform subjects below collect and raise them; the messages
//     asserted are the port's own.
//
//   - `match:` entries now RUN. The retired engine compared `out` only, so
//     `minor.setpath` and `merge.integrity` - thirteen entries whose whole
//     point is `match: {args: ...}`, i.e. what the call did to its
//     ARGUMENTS - asserted nothing about that. Subjects therefore no longer
//     clone their input: an in-place rewrite has to be visible.
//
//   - `.noval` and `.null` are DISTINCT. The retired engine's canonical
//     comparison folded them together; omni's `null` flag decides per
//     section, and the flags below track csharp's.
//
// RUN: cd swift && swift test
// RUN-SOME: swift test --filter StructUtilityTest.testMinor

import Foundation
import XCTest

@testable import UnivecSdk

final class StructUtilityTest: XCTestCase {

  // One corpus runner for the whole suite (XCTest builds a fresh instance
  // per test method, so the runner is static).
  private static var RUN: OmniResolver.Run?
  private static let runLock = NSLock()

  private static func structRun() throws -> OmniResolver.Run {
    runLock.lock()
    defer { runLock.unlock() }
    if let run = RUN { return run }
    let run = try OmniResolver.makeRunner(
      SdkRunner.testJsonPath(), UnivecSDK.testSDK(nil, nil))("struct")
    RUN = run
    return run
  }

  // Run one corpus section through the vendored engine, failing loudly when
  // the category, the section, or its `set` is missing or EMPTY - a renamed
  // fixture must not report PASS while running zero assertions. The case
  // count is printed so a collapse is visible in the log, not just in a
  // red/green bit.
  private func runStruct(
    _ category: String, _ name: String, _ nullFlag: Bool,
    _ subject: @escaping (Value) throws -> Value,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let label = category + "." + name
    do {
      let run = try StructUtilityTest.structRun()

      let cat = run.spec.get(category)
      guard cat.isMap else {
        return XCTFail(
          "struct corpus category missing: \(category) - check .sdk/test/struct/",
          file: file, line: line)
      }

      let section = cat.get(name)
      guard section.isMap else {
        return XCTFail(
          "struct corpus section missing: \(label) - check .sdk/test/struct/",
          file: file, line: line)
      }

      guard let count = section.setCount else {
        return XCTFail(
          "struct corpus section has no set list: \(label) - zero cases would run",
          file: file, line: line)
      }
      guard 0 < count else {
        return XCTFail(
          "struct corpus section is EMPTY: \(label) - zero cases would run",
          file: file, line: line)
      }

      try run.runsetflags(section, nullFlag) { args in
        try subject(args.first ?? .noval)
      }

      print("ok \(label): \(count)/\(count)")
    } catch {
      XCTFail("\(label): \(OmniResolver.message(error))", file: file, line: line)
    }
  }

  // A section of the corpus in the SDK's value model, for the few subjects
  // that need to read fixture data directly.
  private func section(_ category: String, _ name: String) throws -> Value {
    try StructUtilityTest.structRun().spec.get([category, name]).value
  }

  // MARK: - Local helpers

  private func intArg(_ v: Value) -> Int? { v.asInt.map(Int.init) }

  // A RAW fixture read. `gp`/`getprop` is Group A - a stored null reads as
  // absent - so reading a fixture field with it collapses the very
  // distinction the `null: false` sections exist to test (an explicit
  // `alt: null` arrived as "no alt", and `data: null` as "no data").
  // `lookup` is Group B: the stored value, null included, and `.noval` only
  // when the key is genuinely missing.
  private func raw(_ v: Value, _ key: String) -> Value { lookup(v, .string(key)) }

  // An Injection whose `errs` list this suite holds, so the diagnostics
  // struct's Swift port COLLECTS can be raised as the failure the corpus
  // `err:` entries expect. (The C# port raises them from inside Validate;
  // the Swift port does not - see the header note.)
  private func errCollector() -> (Injection, VList) {
    let inj = Injection(val: .noval, parent: .noval)
    let errs = VList()
    inj.errs = errs
    return (inj, errs)
  }

  private func raiseErrs(_ errs: VList) throws {
    if errs.items.isEmpty { return }
    throw OmniResolver.SubjectError(
      errs.items.map { stringify($0) }.joined(separator: " | "))
  }

  // MARK: - Existence

  func testMinorExists() {
    XCTAssertFalse(isnode(.noval))
    XCTAssertTrue(isnode(.map(VMap())))
    XCTAssertEqual(typename(T_string), S_string)
    XCTAssertEqual(escre(.string("a.b")), "a\\.b")
  }

  // MARK: - Minor

  func testMinor() {
    runStruct("minor", "isnode", true) { .bool(isnode($0)) }
    runStruct("minor", "ismap", true) { .bool(ismap($0)) }
    runStruct("minor", "islist", true) { .bool(islist($0)) }
    runStruct("minor", "iskey", false) { .bool(iskey($0)) }
    runStruct("minor", "isempty", false) { .bool(isempty($0)) }
    runStruct("minor", "isfunc", true) { .bool(isfunc($0)) }
    runStruct("minor", "size", false) { .int(Int64(size($0))) }
    runStruct("minor", "typify", false) { .int(Int64(typify($0))) }
    runStruct("minor", "typename", true) { .string(typename(Int($0.asInt ?? 0))) }
    runStruct("minor", "strkey", false) { .string(strkey($0)) }
    runStruct("minor", "keysof", true) { .list(keysof($0).map { Value.string($0) }) }
    runStruct("minor", "clone", false) { clone($0) }
    runStruct("minor", "escre", true) { .string(escre($0)) }
    runStruct("minor", "escurl", true) { .string(escurl($0)) }
    runStruct("minor", "items", true) { .list(items($0).map { Value.list($0) }) }

    runStruct("minor", "haskey", false) {
      .bool(haskey(gp($0, "src"), gp($0, "key")))
    }
    runStruct("minor", "getprop", false) {
      getprop(gp($0, "val"), gp($0, "key"), self.raw($0, "alt"))
    }
    runStruct("minor", "getelem", false) {
      getelem(gp($0, "val"), gp($0, "key"), gp($0, "alt"))
    }
    runStruct("minor", "stringify", false) {
      if case .map(let m) = $0 {
        return .string(stringify(m.entries["val"] ?? .noval,
          m.entries["max"]?.asInt.map(Int.init)))
      }
      return .string(stringify($0))
    }
    runStruct("minor", "jsonify", false) {
      var indent = 2
      var offset = 0
      let flags = gp($0, "flags")
      if case .map = flags {
        if case .int(let n) = gp(flags, "indent") { indent = Int(n) }
        if case .int(let n) = gp(flags, "offset") { offset = Int(n) }
      }
      return .string(jsonify(lookup($0, .string("val")), indent: indent, offset: offset))
    }
    runStruct("minor", "pathify", false) {
      .string(pathify(lookup($0, .string("path")), self.intArg(gp($0, "from"))))
    }
    runStruct("minor", "flatten", true) {
      flatten(gp($0, "val"), self.intArg(gp($0, "depth")))
    }
    runStruct("minor", "filter", true) {
      let checks: [String: (Value, Value) -> Bool] = [
        "gt3": { _, v in (v.asDouble ?? 0) > 3 },
        "lt3": { _, v in (v.asDouble ?? 0) < 3 },
      ]
      let check = strkey(gp($0, "check"))
      return filter(gp($0, "val"), checks[check] ?? { _, _ in false })
    }
    runStruct("minor", "join", false) {
      let sep: String
      if case .string(let s) = gp($0, "sep") { sep = s } else { sep = "," }
      var url = false
      if case .bool(let b) = gp($0, "url") { url = b }
      return .string(join(gp($0, "val"), sep, url))
    }
    runStruct("minor", "slice", false) {
      slice(gp($0, "val"), self.intArg(gp($0, "start")), self.intArg(gp($0, "end")))
    }
    runStruct("minor", "pad", false) {
      let padding = self.intArg(gp($0, "pad"))
      var padchar: Character = " "
      if case .string(let c) = gp($0, "char"), let f = c.first { padchar = f }
      return pad(lookup($0, .string("val")), padding, padchar)
    }

    // setprop/delprop/setpath REWRITE the container they are given, and
    // minor.setpath asserts exactly that through `match: {args: ...}`, so
    // the argument crosses by identity - no clone.
    runStruct("minor", "setprop", true) {
      setprop(gp($0, "parent"), gp($0, "key"), lookup($0, .string("val")))
    }
    runStruct("minor", "delprop", true) {
      delprop(gp($0, "parent"), gp($0, "key"))
    }
    runStruct("minor", "setpath", false) {
      setpath(gp($0, "store"), gp($0, "path"), lookup($0, .string("val")))
    }
  }

  // MARK: - Null semantics
  //
  // The corpus group is `nullsem` - it was called `sentinels` once, and the
  // retired engine kept driving the old name over zero entries.

  func testNullsem() {
    runStruct("nullsem", "getprop", false) {
      getprop(gp($0, "val"), gp($0, "key"), self.raw($0, "alt"))
    }
    runStruct("nullsem", "getelem", false) {
      getelem(gp($0, "val"), gp($0, "key"), gp($0, "alt"))
    }
    runStruct("nullsem", "getpath", false) {
      getpath(gp($0, "store"), gp($0, "path"))
    }
    runStruct("nullsem", "haskey", false) {
      .bool(haskey(gp($0, "src"), gp($0, "key")))
    }
    runStruct("nullsem", "keysof", false) {
      .list(keysof($0).map { Value.string($0) })
    }
  }

  // MARK: - Walk

  func testWalkBasic() {
    let walkpath: WalkApply = { _, v, _, path in
      if case .string(let s) = v {
        return .string(s + "~" + path.joined(separator: "."))
      }
      return v
    }
    runStruct("walk", "basic", true) { walk($0, walkpath) }
  }

  // MARK: - Getpath

  func testGetpathBasic() {
    runStruct("getpath", "basic", true) {
      getpath(gp($0, "store"), gp($0, "path"))
    }
  }

  // MARK: - Merge

  func testMerge() {
    // merge.integrity asserts through `match: {args: ...}` that merge does
    // NOT rewrite the list it was handed, so nothing is cloned here.
    runStruct("merge", "cases", true) { merge($0) }
    runStruct("merge", "array", true) { merge($0) }
    runStruct("merge", "integrity", true) { merge($0) }
    runStruct("merge", "depth", true) {
      merge(gp($0, "val"), self.intArg(gp($0, "depth")) ?? MAXDEPTH)
    }
  }

  // MARK: - Inject

  func testInject() {
    runStruct("inject", "string", true) {
      let inj = Injection(val: .noval, parent: .noval)
      inj.modify = OmniResolver.nullModifier
      return inject(gp($0, "val"), gp($0, "store"), inj)
    }
    runStruct("inject", "deep", true) {
      inject(gp($0, "val"), gp($0, "store"))
    }
  }

  // MARK: - Transform

  func testTransform() {
    for name in ["paths", "cmds", "each", "pack", "ref"] {
      runStruct("transform", name, true) {
        let (inj, errs) = self.errCollector()
        let out = transform(gp($0, "data"), gp($0, "spec"), inj)
        try self.raiseErrs(errs)
        return out
      }
    }
    runStruct("transform", "format", false) {
      let (inj, errs) = self.errCollector()
      let out = transform(gp($0, "data"), gp($0, "spec"), inj)
      try self.raiseErrs(errs)
      return out
    }
    runStruct("transform", "apply", true) {
      let (inj, errs) = self.errCollector()
      let out = transform(gp($0, "data"), gp($0, "spec"), inj)
      try self.raiseErrs(errs)
      return out
    }
    runStruct("transform", "modify", true) {
      let inj = Injection(val: .noval, parent: .noval)
      inj.modify = { val, key, parent, _, _ in
        if case .string(let s) = val, !s.isEmpty {
          setprop(parent, key, .string("@" + s))
        }
      }
      return transform(gp($0, "data"), gp($0, "spec"), inj)
    }
  }

  // MARK: - Validate

  func testValidate() {
    for (name, nullFlag) in [
      ("basic", false), ("child", true), ("one", true),
      ("exact", true), ("invalid", false), ("special", true),
    ] {
      runStruct("validate", name, nullFlag) {
        let (inj, errs) = self.errCollector()
        if case .map(let im) = gp($0, "inj"), let meta = im.entries["meta"]?.asMap {
          inj.meta = meta
        }
        let out = validate(self.raw($0, "data"), self.raw($0, "spec"), inj)
        try self.raiseErrs(errs)
        return out
      }
    }
  }

  // MARK: - Select

  func testSelect() {
    for name in ["basic", "operators", "edge", "alts"] {
      runStruct("select", name, true) {
        select(gp($0, "obj"), gp($0, "query"))
      }
    }
  }
}
