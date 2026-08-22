
import {
  Model,
  ModelEntity,
} from '@voxgig/apidef'

import {
  Content,
  File,
  cmp,
} from '@voxgig/sdkgen'


// Generates a per-entity Direct test: drives the client's Direct() path
// (prepare -> auth -> fetchdef -> fetcher -> response shaping) end-to-end
// against an injected system.fetch mock in live mode. API-shape independent
// (a fixed mock path), so it is green for every SDK.
const TestDirect = cmp(function TestDirect(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity

  const Name = model.const.Name

  const opnames = Object.keys(entity.op || {})
  if (!opnames.includes('load') && !opnames.includes('list')) {
    return
  }

  File({ name: entity.Name + 'DirectTest.' + target.ext }, () => {
    Content(`// ${entity.name} direct API test (generated from the API model).

import XCTest

@testable import ${Name}Sdk

final class ${entity.Name}DirectTest: XCTestCase {
  func testDirectMock() {
    final class CallBox: @unchecked Sendable { var count = 0; var lastUrl = "" }
    let box = CallBox()
    let fetch: SystemFetch = { url, _ in
      box.count += 1
      box.lastUrl = url
      let m = VMap()
      m.entries["status"] = .int(200)
      m.entries["statusText"] = .string("OK")
      m.entries["headers"] = .map(VMap())
      m.entries["json"] = .nat({ () -> Value in .map(vm(("id", .string("direct01")))) } as NativeCall0)
      m.entries["body"] = .string("not-used")
      return .map(m)
    }

    let system = VMap()
    system.entries["fetch"] = .nat(fetch)
    let opts = VMap()
    opts.entries["base"] = .string("http://localhost:8080")
    opts.entries["system"] = .map(system)
    let sdk = ${Name}SDK(opts)

    let args = VMap()
    args.entries["path"] = .string("/${entity.name}")
    args.entries["method"] = .string("GET")
    let result = sdk.direct(args)

    XCTAssertEqual(gp(.map(result), "ok"), .bool(true))
    XCTAssertEqual(gp(.map(result), "status"), .int(200))
    XCTAssertEqual(box.count, 1)
    if let data = gp(.map(result), "data").asMap {
      XCTAssertEqual(data.entries["id"], .string("direct01"))
    } else {
      XCTFail("expected data map")
    }
  }
}
`)
  })
})


export {
  TestDirect
}
