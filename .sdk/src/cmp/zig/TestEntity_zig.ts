
import { cmp, Content } from '@voxgig/sdkgen'

import { zigVarName } from './utility_zig'


// Per-entity model-driven smoke tests. Emits `test "..."` blocks INTO the
// shared generated_test.zig file (opened by Test_zig) — zig's build.zig uses
// an explicit test-file list, so every generated test must live in that one
// file rather than a per-entity file (the go/rust one-file-per-entity layout
// relies on cargo/go auto-discovery, which zig lacks). Each test drives the
// entity through the full pipeline via the offline `test` transport and
// asserts a non-error result. `std`, `sdk`, `h`, `Value` and `vnull()` are in
// scope from the Test_zig header.
const TestEntity = cmp(function TestEntity(props: any) {
  const { target, entity } = props

  const method = zigVarName(entity.name)
  const ops = entity.op || {}

  if (ops.load) {
    Content(`
test "${method}_load_smoke" {
    const fixture = h.jo(&.{.{ "${entity.name}", h.jo(&.{.{ "t01", h.jo(&.{.{ "id", h.vstr("t01") }}) }}) }});
    const testsdk = sdk.test_sdk(h.jo(&.{.{ "entity", fixture }}), vnull());
    const e = testsdk.${method}(vnull());
    const res = e.load(h.jo(&.{.{ "id", h.vstr("t01") }}), vnull());
    switch (res) {
        .ok => |ent| {
            // EVERY operation resolves to the ENTITY, not the record: the
            // payload of EntResult.ok is the entity pointer, and the record is
            // reached through data(). Destructuring it as a Value was a
            // compile error ("expected type 'struct.JsonValue', found
            // '*entity.<name>.<Name>Entity'"), so no generated zig SDK with a
            // loadable entity could build its own test suite.
            const rec = ent.asEntity().data(null);
            try std.testing.expect(std.mem.eql(u8, h.get_str(rec, "id") orelse "", "t01"));
        },
        .err => |er| {
            std.debug.print("${method} load failed: {s}\\n", .{er.msg});
            try std.testing.expect(false);
        },
    }
}
`)
  }

  if (ops.list) {
    Content(`
test "${method}_list_smoke" {
    const fixture = h.jo(&.{.{ "${entity.name}", h.jo(&.{.{ "t01", h.jo(&.{.{ "id", h.vstr("t01") }}) }}) }});
    const testsdk = sdk.test_sdk(h.jo(&.{.{ "entity", fixture }}), vnull());
    const e = testsdk.${method}(vnull());
    const res = e.list(vnull(), vnull());
    try std.testing.expect(res == .ok);
}

test "${method}_stream_smoke" {
    // stream() runs the list op through the full pipeline and returns the
    // result items. Seed two entities via test mode; with the streaming
    // feature active it yields the feature's incremental items, else it falls
    // back to the materialised items — either way every item is yielded.
    const fixture = h.jo(&.{.{ "${entity.name}", h.jo(&.{
        .{ "strm01", h.jo(&.{.{ "id", h.vstr("strm01") }}) },
        .{ "strm02", h.jo(&.{.{ "id", h.vstr("strm02") }}) },
    }) }});
    const sdkopts = h.jo(&.{.{ "feature", h.jo(&.{.{ "streaming", h.jo(&.{.{ "active", h.vbool(true) }}) }}) }});
    const testsdk = sdk.test_sdk(h.jo(&.{.{ "entity", fixture }}), sdkopts);
    const e = testsdk.${method}(vnull());
    const items = e.stream("list", vnull(), vnull());
    try std.testing.expect(items.len == 2);

    // Fallback: streaming inactive still yields both materialised items.
    const plainsdk = sdk.test_sdk(h.jo(&.{.{ "entity", fixture }}), vnull());
    const pe = plainsdk.${method}(vnull());
    const pitems = pe.stream("list", vnull(), vnull());
    try std.testing.expect(pitems.len == 2);
}
`)
  }
})


export {
  TestEntity
}
