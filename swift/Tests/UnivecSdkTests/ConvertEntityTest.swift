// convert entity test (generated from the API model).

import XCTest

@testable import UnivecSdk

final class ConvertEntityTest: XCTestCase {
  func testInstance() {
    let sdk = UnivecSDK.testSDK(nil, nil)
    let ent = sdk.Convert()
    XCTAssertEqual(ent.getName(), "convert")
  }
}
