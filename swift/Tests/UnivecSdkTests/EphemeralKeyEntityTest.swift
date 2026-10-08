// ephemeral_key entity test (generated from the API model).

import XCTest

@testable import UnivecSdk

final class EphemeralKeyEntityTest: XCTestCase {
  func testInstance() {
    let sdk = UnivecSDK.testSDK(nil, nil)
    let ent = sdk.EphemeralKey()
    XCTAssertEqual(ent.getName(), "ephemeral_key")
  }

  // An invalid request fails with validate's own error, before it is sent.
  func testValidate() throws {
    try XCTSkipUnless(EphemeralKeyEntityTest.hasFeature("validate"), "feature not present in this SDK: validate")
    let client = UnivecSDK.testSDK(nil, vm(("feature", .map(vm(("validate", .map(vm(("active", .bool(true))))))))))
    var err: Error? = nil
    do { _ = try client.EphemeralKey().create(vm(("dailyLimit", .string("x")), ("dailyUsed", .int(1)), ("key", .string("x")), ("resetsAt", .string("x"))), nil) } catch { err = error }
    XCTAssertEqual((err as? UnivecError)?.code, "validate_failed",
      "expected validate_failed, got \(String(describing: err))")
  }

  // True when this SDK was generated with the named feature.
  static func hasFeature(_ name: String) -> Bool {
    gp(SdkConfig.makeConfig(), "feature").asMap?.entries[name] != nil
  }
}
