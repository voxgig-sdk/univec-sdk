// model entity test (generated from the API model).

import XCTest

@testable import UnivecSdk

final class ModelEntityTest: XCTestCase {
  func testInstance() {
    let sdk = UnivecSDK.testSDK(nil, nil)
    let ent = sdk.Model()
    XCTAssertEqual(ent.getName(), "model")
  }

  func testStream() async throws {
    // Seed two records (under the test feature's entity key) and activate
    // the streaming feature.
    let fixtures = vm(("entity", .map(vm(("model", .map(vm(
      ("s1", .map(vm(("id", .string("s1"))))),
      ("s2", .map(vm(("id", .string("s2"))))))))))))
    let sdkopts = vm(
      ("feature", .map(vm(("streaming", .map(vm(("active", .bool(true)))))))))
    let sdk = UnivecSDK.testSDK(fixtures, sdkopts)
    let ent = sdk.Model()

    // Materialised list result for the same op.
    let listed = try ent.list(VMap(), nil)
    let listedN = listed.asList?.items.count ?? 0

    // stream("list") yields items via the streaming feature's iterator.
    var streamed: [Value] = []
    let seq = try ent.stream("list", VMap(), nil)
    for await item in seq { streamed.append(item) }
    XCTAssertGreaterThan(streamed.count, 0, "expected stream to yield items")
    XCTAssertEqual(streamed.count, listedN)

    // Fallback: with streaming inactive, stream still yields the materialised
    // items.
    let sdk2 = UnivecSDK.testSDK(fixtures, nil)
    let ent2 = sdk2.Model()
    var streamed2: [Value] = []
    let seq2 = try ent2.stream("list", VMap(), nil)
    for await item in seq2 { streamed2.append(item) }
    XCTAssertEqual(streamed2.count, listedN)
  }

  // A failed operation throws from a stream as it does from the operation; under
  // throw false the stream ends quietly. The caller's ctrl stays its own.
  func testStreamError() async throws {
    let offline = vm(("net", .map(vm(("offline", .bool(true))))))
    var err: Error? = nil
    do { _ = try UnivecSDK.testSDK(offline, nil).Model().stream("list", VMap(), nil) } catch { err = error }
    XCTAssertTrue((err as? UnivecError)?.message.contains("offline") ?? false,
      "expected the transport failure to raise from the stream, got \(String(describing: err))")

    var quiet: [Value] = []
    let seq = try UnivecSDK.testSDK(offline, nil).Model()
      .stream("list", VMap(), vm(("ctrl", .map(vm(("throw", .bool(false)))))))
    for await item in seq { quiet.append(item) }
    XCTAssertEqual(quiet.count, 0, "throw false should end the stream quietly")

    if ModelEntityTest.hasFeature("rbac") {
      let denied = UnivecSDK.testSDK(nil,
        vm(("feature", .map(vm(("rbac", .map(vm(("active", .bool(true)), ("deny", .bool(true))))))))))
      var denyerr: Error? = nil
      do { _ = try denied.Model().stream("list", VMap(), nil) } catch { denyerr = error }
      XCTAssertEqual((denyerr as? UnivecError)?.code, "rbac_denied",
        "expected the rbac denial to raise from the stream, got \(String(describing: denyerr))")
    }
  }

  func testStreamCtrl() async throws {
    let explain = VMap()
    let ctrl = vm(("explain", .map(explain)))
    let seq = try UnivecSDK.testSDK(nil, nil).Model().stream("list", VMap(), vm(("ctrl", .map(ctrl))))
    for await _ in seq {}
    XCTAssertEqual(ctrl.entries.count, 1, "the stream changed the caller's ctrl")
    XCTAssertTrue(ctrl.entries["explain"]?.asMap === explain, "the caller's explain record is not its own")
    XCTAssertFalse(explain.entries.isEmpty, "the caller's explain record was not filled")
  }

  // A swift hook cannot throw, so the failure here is the transport's: makeError
  // fires PreUnexpected for it, under throw false too.
  func testUnexpected() throws {
    final class CountHook: BaseFeature {
      var unexpected = 0
      override init() { super.init(); name = "counthook"; version = "0.0.1"; active = true }
      override func preUnexpected(_ ctx: Context) { unexpected += 1 }
    }
    let hook = CountHook()
    let sdk = UnivecSDK.testSDK(vm(("net", .map(vm(("offline", .bool(true)))))), nil)
    sdk.features.append(hook)
    var err: Error? = nil
    do { _ = try sdk.Model().list(VMap(), nil) } catch { err = error }
    XCTAssertTrue((err as? UnivecError)?.message.contains("offline") ?? false,
      "expected the transport failure, got \(String(describing: err))")
    XCTAssertGreaterThan(hook.unexpected, 0, "PreUnexpected did not fire")

    let fired = hook.unexpected
    _ = try sdk.Model().list(VMap(), vm(("throw", .bool(false))))
    XCTAssertGreaterThan(hook.unexpected, fired, "PreUnexpected did not fire under throw false")
  }

  // An invalid request fails with validate's own error, before it is sent.
  func testValidate() throws {
    try XCTSkipUnless(ModelEntityTest.hasFeature("validate"), "feature not present in this SDK: validate")
    let client = UnivecSDK.testSDK(nil, vm(("feature", .map(vm(("validate", .map(vm(("active", .bool(true))))))))))
    var err: Error? = nil
    do { _ = try client.Model().list(vm(("executionProvider", .int(1))), nil) } catch { err = error }
    XCTAssertEqual((err as? UnivecError)?.code, "validate_failed",
      "expected validate_failed, got \(String(describing: err))")
  }

  // True when this SDK was generated with the named feature.
  static func hasFeature(_ name: String) -> Bool {
    gp(SdkConfig.makeConfig(), "feature").asMap?.entries[name] != nil
  }
}
