// embed entity test (generated from the API model).

import XCTest

@testable import UnivecSdk

final class EmbedEntityTest: XCTestCase {
  func testInstance() {
    let sdk = UnivecSDK.testSDK(nil, nil)
    let ent = sdk.Embed()
    XCTAssertEqual(ent.getName(), "embed")
  }
}
