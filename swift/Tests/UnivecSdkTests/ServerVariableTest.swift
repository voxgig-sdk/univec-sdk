// A templated base URL takes each {name} from the `server` option. A missing
// or empty value is an error; test mode fills in test-<name>. Construction
// traps on that error, which XCTest cannot observe, so the error case calls
// the resolver that construction uses.

import XCTest

@testable import UnivecSdk

final class ServerVariableTest: XCTestCase {
  // A variable no API declares, so the API's own server defaults cannot fill it.
  let base = "https://api.example.test/bot{zzvar}"

  func testAMissingOrEmptyValueIsAnError() {
    for server in [VMap(), vm(("zzvar", .string("")))] {
      let opts = vm(("base", .string(base)), ("server", .map(server)))
      XCTAssertThrowsError(try resolveServerBase(base, opts, VMap(), nil)) { error in
        let err = error as? UnivecError
        XCTAssertEqual(err?.code, "server_var_required")
        XCTAssertTrue(err?.message.contains("the server variable 'zzvar' is required") ?? false)
        XCTAssertTrue(err?.message.contains(self.base) ?? false)
      }
    }
  }

  func testAServerValueFillsTheBase() {
    let client = UnivecSDK(vm(
      ("base", .string(base)), ("server", .map(vm(("zzvar", .string("T1")))))))
    XCTAssertEqual(client.optionsMap().entries["base"], Value.string("https://api.example.test/botT1"))
  }

  func testTestModeFillsTheBase() {
    let client = UnivecSDK(vm(
      ("base", .string(base)), ("test", .map(vm(("active", .bool(true)))))))
    XCTAssertEqual(client.optionsMap().entries["base"],
      Value.string("https://api.example.test/bottest-zzvar"))

    let mock = UnivecSDK.testSDK(nil, vm(("base", .string(base))))
    XCTAssertEqual(mock.optionsMap().entries["base"],
      Value.string("https://api.example.test/bottest-zzvar"))
  }
}
