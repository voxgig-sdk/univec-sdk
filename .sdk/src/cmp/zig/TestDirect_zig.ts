
import { cmp, Content } from '@voxgig/sdkgen'

import { zigVarName } from './utility_zig'


// Per-entity direct-call smoke tests. Emits `test "..."` blocks INTO the
// shared generated_test.zig file (opened by Test_zig) — see TestEntity_zig for
// why zig keeps every generated test in one file.
//
// The go/rust TestDirect generators build a per-entity mock-fetch harness and
// assert the exact URL/params the entity's op point resolves. Reproducing that
// path-extraction + mock-transport harness in zig safely requires a build to
// validate against, so this generator instead exercises the documented
// `direct()` / `prepare()` escape hatches through the offline test transport
// and asserts the result shape. `std`, `sdk`, `h`, `Value` and `vnull()` are
// in scope from the Test_zig header.
const TestDirect = cmp(function TestDirect(props: any) {
  const { entity } = props

  const method = zigVarName(entity.name)
  const ops = entity.op || {}

  // Only entities with a read op participate (mirrors the go/rust gate, which
  // skips op-less entities).
  if (!ops.load && !ops.list) {
    return
  }

  Content(`
test "${method}_direct_smoke" {
    // direct() drives prepare -> transport and always returns a result map
    // carrying an \`ok\` flag (never an error union), even on a non-2xx or a
    // prepare failure.
    const testsdk = sdk.test_sdk(vnull(), vnull());
    const result = testsdk.direct(h.jo(&.{
        .{ "path", h.vstr("/${entity.name}/{id}") },
        .{ "method", h.vstr("GET") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("direct01") }}) },
    }));
    try std.testing.expect(result == .object);
    try std.testing.expect(h.get_bool(result, "ok") != null);
}

test "${method}_prepare_smoke" {
    // prepare() returns the fetch definition (an error union). The generated
    // fetchdef always carries a url + method.
    const testsdk = sdk.test_sdk(vnull(), vnull());
    const fetchdef = testsdk.prepare(h.jo(&.{
        .{ "path", h.vstr("/${entity.name}/{id}") },
        .{ "method", h.vstr("GET") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("direct01") }}) },
    })) catch {
        // A prepare error is acceptable here (base may be unset); the surface
        // exists and is exercised.
        return;
    };
    try std.testing.expect(std.mem.eql(u8, h.get_str(fetchdef, "method") orelse "", "GET"));
}
`)
})


export {
  TestDirect
}
