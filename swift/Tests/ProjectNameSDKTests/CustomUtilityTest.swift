// Custom utility overrides supplied via options.utility land on the client
// utility's custom map. Swift twin of the go custom_utility_test.go.

import XCTest

@testable import UnivecSdk

final class CustomUtilityTest: XCTestCase {
  func testBasic() {
    let names = [
      "auth", "body", "contextify", "done", "error", "findparam",
      "fullurl", "headers", "method", "operator", "params", "query",
      "reqform", "request", "resbasic", "resbody", "resform",
      "resheaders", "response", "result", "spec",
    ]

    let utilityOpt = VMap()
    for name in names {
      let tag = name.uppercased()
      let fn: () -> VMap = {
        let m = VMap()
        m.entries["util"] = .string(tag)
        return m
      }
      utilityOpt.entries[name] = .nat(fn)
    }

    let opts = VMap()
    opts.entries["apikey"] = .string("APIKEY01")
    opts.entries["utility"] = .map(utilityOpt)

    let client = UnivecSDK.testSDK(nil, opts)
    let u = client.getUtility()

    for name in names {
      guard let raw = u.custom[name], let fn = raw as? () -> VMap else {
        XCTFail("expected custom utility \"\(name)\" to exist")
        continue
      }
      let result = fn()
      XCTAssertEqual(result.entries["util"], .string(name.uppercased()))
    }
  }
}
