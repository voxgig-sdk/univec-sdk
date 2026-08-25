// Network-behaviour simulation over the offline mock transport. Drives the
// transport through Direct(), which needs no entity, so these run for every
// generated SDK. Swift twin of the go netsim_test.go.

import XCTest

@testable import UnivecSdk

final class NetsimTest: XCTestCase {
  private func directPing(_ net: VMap) -> VMap {
    let testopts = VMap()
    testopts.entries["net"] = .map(net)
    let client = UnivecSDK.testSDK(testopts, nil)
    let args = VMap()
    args.entries["path"] = .string("/ping")
    return client.direct(args)
  }

  func testOfflineSimulationFailsRequest() {
    let net = VMap()
    net.entries["offline"] = .bool(true)
    let res = directPing(net)
    XCTAssertEqual(gp(.map(res), "ok"), .bool(false), "offline network must fail the call")
  }

  func testFailstatusSimulationSurfacesStatus() {
    let net = VMap()
    net.entries["failTimes"] = .int(1)
    net.entries["failStatus"] = .int(503)
    let res = directPing(net)
    XCTAssertEqual(gp(.map(res), "ok"), .bool(false), "expected failed call")
    XCTAssertEqual(toInt(gp(.map(res), "status")), 503)
  }

  func testLatencySimulationDelaysRequest() {
    let delay = 60
    let net = VMap()
    net.entries["latency"] = .int(Int64(delay))
    let start = Date()
    _ = directPing(net)
    let elapsedMs = Date().timeIntervalSince(start) * 1000
    XCTAssertGreaterThanOrEqual(elapsedMs, Double(delay - 25),
      "expected >= \(delay - 25)ms latency, got \(elapsedMs)ms")
  }

  func testPlainTestSdkWorksWithoutNet() {
    let client = UnivecSDK.testSDK(nil, nil)
    XCTAssertEqual(client.mode, "test")
  }
}
