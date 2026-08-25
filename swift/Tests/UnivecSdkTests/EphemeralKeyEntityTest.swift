// ephemeral_key entity test (generated from the API model).

import XCTest

@testable import UnivecSdk

final class EphemeralKeyEntityTest: XCTestCase {
  func testInstance() {
    let sdk = UnivecSDK.testSDK(nil, nil)
    let ent = sdk.EphemeralKey()
    XCTAssertEqual(ent.getName(), "ephemeral_key")
  }
}
