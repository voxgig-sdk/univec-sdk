
import {
  Content,
  File,
  cmp,
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

  const hasList = Object.keys(entity.op || {}).includes('list')

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

    // Stream test (PR #4): the entity `stream` method runs the op pipeline and
    // returns an AsyncStream. With the streaming feature active it yields from
    // the feature's incremental iterator; otherwise it falls back to the
    // materialised items. Only emitted for entities that support list.
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
`)
    }

    Content(`}
`)
  })
})


export {
  TestEntity
}
