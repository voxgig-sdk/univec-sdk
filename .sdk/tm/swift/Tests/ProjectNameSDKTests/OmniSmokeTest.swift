// Smoke tests for the vendored omni runner ITSELF: a runner that cannot
// FAIL a bad entry would turn every corpus suite vacuously green, so pin
// the failure paths, not just the happy one. (The Swift peer of
// tm/csharp/test/OmniSmokeTest.cs and tm/go/test/omnismoke_test.go.)
//
// Nothing here imports Omni: the resolver is the only file that may
// (OmniResolver decision 1), so the spec is built in the SDK's own Value
// model and engine failures are recognised through
// OmniResolver.isOmniError.

import XCTest

@testable import UnivecSdk

final class OmniSmokeTest: XCTestCase {

  // A minimal in-memory spec: no fixture file, no OMNI block (lenient v0,
  // like the shared corpus).
  private func smokeSpec() -> Value {
    func entry(_ pairs: (String, Value)...) -> Value {
      let m = VMap()
      for (k, v) in pairs { m.entries[k] = v }
      return .map(m)
    }
    func group(_ items: Value...) -> Value {
      let m = VMap()
      m.entries["set"] = .list(items)
      return .map(m)
    }

    let smoke = VMap()
    smoke.entries["basic"] = group(
      entry(("in", .int(1)), ("out", .int(2))),
      entry(("in", .int(41)), ("out", .int(42))))
    smoke.entries["bad"] = group(
      entry(("in", .int(1)), ("out", .int(999))))
    smoke.entries["err"] = group(
      entry(("in", .int(0)), ("err", .string("zero refused"))))

    let primary = VMap()
    primary.entries["smoke"] = .map(smoke)

    let root = VMap()
    root.entries["primary"] = .map(primary)
    return .map(root)
  }

  // The subject under test: increment, but refuse zero.
  private func smokeInc(_ args: [Value]) throws -> Value {
    let n = args.first?.asInt ?? 0
    if 0 == n {
      throw OmniResolver.SubjectError("smoke: zero refused")
    }
    return .int(n + 1)
  }

  private func smokeRun() throws -> OmniResolver.Run {
    let client = UnivecSDK.testSDK(nil, nil)
    let run = try OmniResolver.makeRunner(smokeSpec(), client)("smoke")
    XCTAssertTrue(run.spec.isMap, "smoke spec did not resolve")
    return run
  }

  func testRunsetPassesACorrectSubject() throws {
    let run = try smokeRun()
    XCTAssertEqual(run.set("basic").setCount, 2, "smoke basic must carry 2 entries")
    try run.runset(run.set("basic"), smokeInc)
  }

  func testRunsetFailsAWrongResult() throws {
    let run = try smokeRun()

    XCTAssertThrowsError(try run.runset(run.set("bad"), smokeInc)) { err in
      XCTAssertTrue(OmniResolver.isOmniError(err),
        "expected an engine failure, got: \(err)")
      XCTAssertTrue(OmniResolver.message(err).contains("result mismatch"),
        "expected a result mismatch failure, got: \(OmniResolver.message(err))")
    }
  }

  func testExpectedErrorIsMatchedAndAMissingOneFails() throws {
    let run = try smokeRun()

    // The erroring subject satisfies the expected-error entry.
    try run.runset(run.set("err"), smokeInc)

    // A subject that does NOT raise must fail that same entry.
    XCTAssertThrowsError(
      try run.runset(run.set("err"), { args in args.first ?? .noval })
    ) { err in
      XCTAssertTrue(OmniResolver.message(err).contains("expected error did not occur"),
        "expected an expected-error failure, got: \(OmniResolver.message(err))")
    }
  }

  // The engine must also refuse a group that does not exist at all, rather
  // than reporting a silent pass over zero entries.
  func testMissingGroupFails() throws {
    let run = try smokeRun()
    XCTAssertNil(run.set("nosuchgroup").setCount,
      "a missing group must not present a set")
    XCTAssertThrowsError(try run.runset(run.set("nosuchgroup"), smokeInc)) { err in
      XCTAssertTrue(OmniResolver.message(err).contains("no set"),
        "expected a missing-set failure, got: \(OmniResolver.message(err))")
    }
  }
}
