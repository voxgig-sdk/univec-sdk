
import { cmp, Content } from '@voxgig/sdkgen'


// Validates the documented README/REFERENCE quick-start examples for the Zig
// SDK.
//
// DESIGN NOTE vs the go/rust gates (ReadmeExamplesTest_go.ts /
// ReadmeExamplesTest_rust.ts): the go version shells out to `go build`/`go run`
// to compile and run every fenced block; the rust version reads the doc files
// and checks that each block is structurally well-formed. Zig's test harness
// uses an EXPLICIT test-file list in build.zig (no auto-discovery of test/*.zig
// and no per-block temp compilation), and the doc files are not on the package
// path at test time — so neither a filesystem scan nor a per-snippet compile can
// be authored safely without a build to validate against.
//
// Instead this gate emits a real, always-compiling zig `test` block INTO the
// shared generated_test.zig (the only generated test file build.zig picks up).
// It exercises the exact top-level entry points the docs advertise — the
// test-mode constructor and the `direct()` escape hatch — so the documented
// quick-start surface is guaranteed to exist and run. Upgrading it to a true
// per-block compile gate is left as a follow-up.
const ReadmeExamplesTest = cmp(function ReadmeExamplesTest(props: any) {
  const { ctx$: { model } } = props

  Content(`
// Documented quick-start surface (README.md / REFERENCE.md). Exercises the
// test-mode constructor and the direct() escape hatch exactly as documented.
test "readme_quickstart_surface" {
    // \`sdk.test_sdk(...)\` — the documented mock constructor.
    const client = sdk.test_sdk(vnull(), vnull());
    try std.testing.expect(std.mem.eql(u8, client.mode, "test"));

    // \`client.direct(...)\` — the documented escape hatch. It always returns a
    // result map carrying an \`ok\` flag (never an error union).
    const result = client.direct(h.jo(&.{
        .{ "path", h.vstr("/api/resource/{id}") },
        .{ "method", h.vstr("GET") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("example") }}) },
    }));
    try std.testing.expect(result == .object);
    try std.testing.expect(h.get_bool(result, "ok") != null);

    // \`client.prepare(...)\` — build a request without sending it.
    const fetchdef = client.prepare(h.jo(&.{
        .{ "path", h.vstr("/api/resource/{id}") },
        .{ "method", h.vstr("GET") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("example") }}) },
    })) catch h.vnull();
    _ = fetchdef;
}
`)
})


export {
  ReadmeExamplesTest
}
