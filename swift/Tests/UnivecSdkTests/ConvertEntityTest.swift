// convert entity test (generated from the API model).

import XCTest

@testable import UnivecSdk

final class ConvertEntityTest: XCTestCase {
  func testInstance() {
    let sdk = UnivecSDK.testSDK(nil, nil)
    let ent = sdk.Convert()
    XCTAssertEqual(ent.getName(), "convert")
  }

  // An invalid request fails with validate's own error, before it is sent.
  func testValidate() throws {
    try XCTSkipUnless(ConvertEntityTest.hasFeature("validate"), "feature not present in this SDK: validate")
    let client = UnivecSDK.testSDK(nil, vm(("feature", .map(vm(("validate", .map(vm(("active", .bool(true))))))))))
    var err: Error? = nil
    do { _ = try client.Convert().create(vm(("embeddings", .string("x")), ("source_model", .int(1)), ("target_model", .string("x"))), nil) } catch { err = error }
    XCTAssertEqual((err as? UnivecError)?.code, "validate_failed",
      "expected validate_failed, got \(String(describing: err))")
  }

  // True when this SDK was generated with the named feature.
  static func hasFeature(_ name: String) -> Bool {
    gp(SdkConfig.makeConfig(), "feature").asMap?.entries[name] != nil
  }
}
