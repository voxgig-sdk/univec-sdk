// embed entity test (generated from the API model).

import XCTest

@testable import UnivecSdk

final class EmbedEntityTest: XCTestCase {
  func testInstance() {
    let sdk = UnivecSDK.testSDK(nil, nil)
    let ent = sdk.Embed()
    XCTAssertEqual(ent.getName(), "embed")
  }

  // An invalid request fails with validate's own error, before it is sent.
  func testValidate() throws {
    try XCTSkipUnless(EmbedEntityTest.hasFeature("validate"), "feature not present in this SDK: validate")
    let client = UnivecSDK.testSDK(nil, vm(("feature", .map(vm(("validate", .map(vm(("active", .bool(true))))))))))
    var err: Error? = nil
    do { _ = try client.Embed().create(vm(("embeddings", .string("x")), ("model", .int(1)), ("texts", .string("x"))), nil) } catch { err = error }
    XCTAssertEqual((err as? UnivecError)?.code, "validate_failed",
      "expected validate_failed, got \(String(describing: err))")
  }

  // True when this SDK was generated with the named feature.
  static func hasFeature(_ name: String) -> Bool {
    gp(SdkConfig.makeConfig(), "feature").asMap?.entries[name] != nil
  }
}
