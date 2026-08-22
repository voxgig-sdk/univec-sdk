
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, File, Content, entityCollection } from '@voxgig/sdkgen'

import { TestEntity } from './TestEntity_zig'
import { TestDirect } from './TestDirect_zig'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_zig'


// Generated tests. The bulk of behavioural coverage lives in the hand-written
// template suite (test/*.zig, copied verbatim): the struct corpus, the
// pipeline, every feature, and the cross-language gotchas. Here we emit the
// model-driven smoke tests.
//
// zig's build.zig picks up an EXPLICIT test-file list, so every generated test
// must land in the single `test/generated_test.zig` file it already lists —
// the per-entity generators (TestEntity, TestDirect) and the readme-examples
// gate all emit their `test` blocks INTO this one open File rather than opening
// their own (the go/rust one-file-per-entity split relies on auto-discovery
// zig does not have).
const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const entity = each(entityCollection(model))
    .filter((e: any) => false !== e.active)

  Folder({ name: 'test' }, () => {
    File({ name: 'generated_test.' + target.ext }, () => {

      Content(`// Generated smoke tests (model-driven). Drive each entity through the
// offline test transport and assert a non-error result.

const std = @import("std");
const sdk = @import("sdk");
const h = sdk.h;
const Value = sdk.Value;

fn vnull() Value {
    return Value{ .null = {} };
}

test "sdk_constructs_in_test_mode" {
    const testsdk = sdk.testSdk();
    try std.testing.expect(std.mem.eql(u8, testsdk.mode, "test"));
}
`)

      each(entity, (ent: ModelEntity) => {
        TestEntity({ target, entity: ent })
        TestDirect({ target, entity: ent })
      })

      // Validate the documented zig quick-start examples run.
      ReadmeExamplesTest({ target })
    })
  })
})


export {
  Test
}
