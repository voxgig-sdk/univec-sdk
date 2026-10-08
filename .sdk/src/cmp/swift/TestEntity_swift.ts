
import {
  Content,
  File,
  cmp,
  invalidRequest,
  opReachable,
} from '@voxgig/sdkgen'


// Generates a per-entity smoke test: the entity accessor returns a bound
// entity in test mode. The full operation pipeline is exercised end-to-end by
// the shared template suites (PrimaryUtility, Pipeline, Feature, Netsim) plus
// the generated Direct test; this keeps the generated per-entity test API-shape
// independent (no fixture/flow coupling) so it is green for every SDK.
const TestEntity = cmp(function TestEntity(props: any) {
  const model = props.ctx$.model
  const { target, entity } = props
  const Name = model.const.Name

  // The stream test lists with no match, so a bare call must reach a route.
  const hasList = opReachable(entity.op?.list, [])

  File({ name: entity.Name + 'EntityTest.' + target.ext }, () => {
    Content(`// ${entity.name} entity test (generated from the API model).

import XCTest

@testable import ${Name}Sdk

final class ${entity.Name}EntityTest: XCTestCase {
  func testInstance() {
    let sdk = ${Name}SDK.testSDK(nil, nil)
    let ent = sdk.${entity.Name}()
    XCTAssertEqual(ent.getName(), "${entity.name}")
  }
`)

    if (hasList) {
      Content(`
  func testStream() async throws {
    // Seed two records (under the test feature's entity key) and activate
    // the streaming feature.
    let fixtures = vm(("entity", .map(vm(("${entity.name}", .map(vm(
      ("s1", .map(vm(("id", .string("s1"))))),
      ("s2", .map(vm(("id", .string("s2"))))))))))))
    let sdkopts = vm(
      ("feature", .map(vm(("streaming", .map(vm(("active", .bool(true)))))))))
    let sdk = ${Name}SDK.testSDK(fixtures, sdkopts)
    let ent = sdk.${entity.Name}()

    // Materialised list result for the same op.
    let listed = try ent.list(VMap(), nil)
    let listedN = listed.asList?.items.count ?? 0

    // stream("list") yields items via the streaming feature's iterator.
    var streamed: [Value] = []
    let seq = try ent.stream("list", VMap(), nil)
    for await item in seq { streamed.append(item) }
    XCTAssertGreaterThan(streamed.count, 0, "expected stream to yield items")
    XCTAssertEqual(streamed.count, listedN)

    // Fallback: with streaming inactive, stream still yields the materialised
    // items.
    let sdk2 = ${Name}SDK.testSDK(fixtures, nil)
    let ent2 = sdk2.${entity.Name}()
    var streamed2: [Value] = []
    let seq2 = try ent2.stream("list", VMap(), nil)
    for await item in seq2 { streamed2.append(item) }
    XCTAssertEqual(streamed2.count, listedN)
  }

  // A failed operation throws from a stream as it does from the operation; under
  // throw false the stream ends quietly. The caller's ctrl stays its own.
  func testStreamError() async throws {
    let offline = vm(("net", .map(vm(("offline", .bool(true))))))
    var err: Error? = nil
    do { _ = try ${Name}SDK.testSDK(offline, nil).${entity.Name}().stream("list", VMap(), nil) } catch { err = error }
    XCTAssertTrue((err as? ${Name}Error)?.message.contains("offline") ?? false,
      "expected the transport failure to raise from the stream, got \\(String(describing: err))")

    var quiet: [Value] = []
    let seq = try ${Name}SDK.testSDK(offline, nil).${entity.Name}()
      .stream("list", VMap(), vm(("ctrl", .map(vm(("throw", .bool(false)))))))
    for await item in seq { quiet.append(item) }
    XCTAssertEqual(quiet.count, 0, "throw false should end the stream quietly")

    if ${entity.Name}EntityTest.hasFeature("rbac") {
      let denied = ${Name}SDK.testSDK(nil,
        vm(("feature", .map(vm(("rbac", .map(vm(("active", .bool(true)), ("deny", .bool(true))))))))))
      var denyerr: Error? = nil
      do { _ = try denied.${entity.Name}().stream("list", VMap(), nil) } catch { denyerr = error }
      XCTAssertEqual((denyerr as? ${Name}Error)?.code, "rbac_denied",
        "expected the rbac denial to raise from the stream, got \\(String(describing: denyerr))")
    }
  }

  func testStreamCtrl() async throws {
    let explain = VMap()
    let ctrl = vm(("explain", .map(explain)))
    let seq = try ${Name}SDK.testSDK(nil, nil).${entity.Name}().stream("list", VMap(), vm(("ctrl", .map(ctrl))))
    for await _ in seq {}
    XCTAssertEqual(ctrl.entries.count, 1, "the stream changed the caller's ctrl")
    XCTAssertTrue(ctrl.entries["explain"]?.asMap === explain, "the caller's explain record is not its own")
    XCTAssertFalse(explain.entries.isEmpty, "the caller's explain record was not filled")
  }

  // A swift hook cannot throw, so the failure here is the transport's: makeError
  // fires PreUnexpected for it, under throw false too.
  func testUnexpected() throws {
    final class CountHook: BaseFeature {
      var unexpected = 0
      override init() { super.init(); name = "counthook"; version = "0.0.1"; active = true }
      override func preUnexpected(_ ctx: Context) { unexpected += 1 }
    }
    let hook = CountHook()
    let sdk = ${Name}SDK.testSDK(vm(("net", .map(vm(("offline", .bool(true)))))), nil)
    sdk.features.append(hook)
    var err: Error? = nil
    do { _ = try sdk.${entity.Name}().list(VMap(), nil) } catch { err = error }
    XCTAssertTrue((err as? ${Name}Error)?.message.contains("offline") ?? false,
      "expected the transport failure, got \\(String(describing: err))")
    XCTAssertGreaterThan(hook.unexpected, 0, "PreUnexpected did not fire")

    let fired = hook.unexpected
    _ = try sdk.${entity.Name}().list(VMap(), vm(("throw", .bool(false))))
    XCTAssertGreaterThan(hook.unexpected, fired, "PreUnexpected did not fire under throw false")
  }
`)
    }

    const bad = invalidRequest(entity)
    if (null != bad) {
      const args = Object.entries(bad.args)
        .map(([k, v]) => '(' + JSON.stringify(k) + ', ' + swiftValue(v) + ')').join(', ')
      Content(`
  // An invalid request fails with validate's own error, before it is sent.
  func testValidate() throws {
    try XCTSkipUnless(${entity.Name}EntityTest.hasFeature("validate"), "feature not present in this SDK: validate")
    let client = ${Name}SDK.testSDK(nil, vm(("feature", .map(vm(("validate", .map(vm(("active", .bool(true))))))))))
    var err: Error? = nil
    do { _ = try client.${entity.Name}().${bad.op}(vm(${args}), nil) } catch { err = error }
    XCTAssertEqual((err as? ${Name}Error)?.code, "validate_failed",
      "expected validate_failed, got \\(String(describing: err))")
  }
`)
    }

    Content(`
  // True when this SDK was generated with the named feature.
  static func hasFeature(_ name: String) -> Bool {
    gp(SdkConfig.makeConfig(), "feature").asMap?.entries[name] != nil
  }
}
`)
  })
})


function swiftValue(v: any): string {
  return 'number' === typeof v ? '.int(' + v + ')' :
    'boolean' === typeof v ? '.bool(' + v + ')' : '.string(' + JSON.stringify(v) + ')'
}


export {
  TestEntity
}
