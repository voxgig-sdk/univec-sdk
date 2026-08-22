// Univec SDK exists test.

import XCTest

@testable import UnivecSdk

final class ExistsTest: XCTestCase {
  func testMode() {
    let testsdk = UnivecSDK.testSDK(nil, nil)
    XCTAssertEqual(testsdk.mode, "test")
  }
}
