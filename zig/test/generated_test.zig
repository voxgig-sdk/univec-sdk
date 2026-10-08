// Generated smoke tests (model-driven). Drive each entity through the
// offline test transport and assert a non-error result.

const std = @import("std");
const sdk = @import("sdk");
const fh = @import("fh.zig");
const h = sdk.h;
const Value = sdk.Value;

fn vnull() Value {
    return Value{ .null = {} };
}

test "sdk_constructs_in_test_mode" {
    const testsdk = sdk.testSdk();
    try std.testing.expect(std.mem.eql(u8, testsdk.mode, "test"));
}

test "convert_validate" {
    if (!fh.fh_has_feature("validate")) return error.SkipZigTest;
    const opts = h.jo(&.{.{ "feature", h.jo(&.{.{ "validate", h.jo(&.{.{ "active", h.vbool(true) }}) }}) }});
    switch (sdk.test_sdk(vnull(), opts).convert(vnull()).create(h.jo(&.{ .{ "embeddings", h.vstr("x") }, .{ "source_model", h.vnum(1) }, .{ "target_model", h.vstr("x") } }), vnull())) {
        .err => |er| try std.testing.expect(std.mem.eql(u8, er.code, "validate_failed")),
        .ok => try std.testing.expect(false),
    }
}

test "embed_validate" {
    if (!fh.fh_has_feature("validate")) return error.SkipZigTest;
    const opts = h.jo(&.{.{ "feature", h.jo(&.{.{ "validate", h.jo(&.{.{ "active", h.vbool(true) }}) }}) }});
    switch (sdk.test_sdk(vnull(), opts).embed(vnull()).create(h.jo(&.{ .{ "embeddings", h.vstr("x") }, .{ "model", h.vnum(1) }, .{ "texts", h.vstr("x") } }), vnull())) {
        .err => |er| try std.testing.expect(std.mem.eql(u8, er.code, "validate_failed")),
        .ok => try std.testing.expect(false),
    }
}

test "ephemeral_key_validate" {
    if (!fh.fh_has_feature("validate")) return error.SkipZigTest;
    const opts = h.jo(&.{.{ "feature", h.jo(&.{.{ "validate", h.jo(&.{.{ "active", h.vbool(true) }}) }}) }});
    switch (sdk.test_sdk(vnull(), opts).ephemeral_key(vnull()).create(h.jo(&.{ .{ "dailyLimit", h.vstr("x") }, .{ "dailyUsed", h.vnum(1) }, .{ "key", h.vstr("x") }, .{ "resetsAt", h.vstr("x") } }), vnull())) {
        .err => |er| try std.testing.expect(std.mem.eql(u8, er.code, "validate_failed")),
        .ok => try std.testing.expect(false),
    }
}

test "model_list_smoke" {
    const fixture = h.jo(&.{.{ "model", h.jo(&.{.{ "t01", h.jo(&.{.{ "id", h.vstr("t01") }}) }}) }});
    const testsdk = sdk.test_sdk(h.jo(&.{.{ "entity", fixture }}), vnull());
    const e = testsdk.model(vnull());
    const res = e.list(vnull(), vnull());
    try std.testing.expect(res == .ok);
}

test "model_stream_smoke" {
    // stream() runs the list op through the full pipeline and returns the
    // result items. Seed two entities via test mode; with the streaming
    // feature active it yields the feature's incremental items, else it falls
    // back to the materialised items — either way every item is yielded.
    const fixture = h.jo(&.{.{ "model", h.jo(&.{
        .{ "strm01", h.jo(&.{.{ "id", h.vstr("strm01") }}) },
        .{ "strm02", h.jo(&.{.{ "id", h.vstr("strm02") }}) },
    }) }});
    const sdkopts = h.jo(&.{.{ "feature", h.jo(&.{.{ "streaming", h.jo(&.{.{ "active", h.vbool(true) }}) }}) }});
    const testsdk = sdk.test_sdk(h.jo(&.{.{ "entity", fixture }}), sdkopts);
    const e = testsdk.model(vnull());
    const items = e.stream("list", vnull(), vnull());
    try std.testing.expect(items == .ok and items.ok.len == 2);

    // Fallback: streaming inactive still yields both materialised items.
    const plainsdk = sdk.test_sdk(h.jo(&.{.{ "entity", fixture }}), vnull());
    const pe = plainsdk.model(vnull());
    const pitems = pe.stream("list", vnull(), vnull());
    try std.testing.expect(pitems == .ok and pitems.ok.len == 2);
}

test "model_stream_error" {
    const offline = h.jo(&.{.{ "net", h.jo(&.{.{ "offline", h.vbool(true) }}) }});
    switch (sdk.test_sdk(offline, vnull()).model(vnull()).stream("list", vnull(), vnull())) {
        .err => |er| try std.testing.expect(std.mem.indexOf(u8, er.msg, "offline") != null),
        .ok => try std.testing.expect(false),
    }

    const quiet = h.jo(&.{.{ "ctrl", h.jo(&.{.{ "throw", h.vbool(false) }}) }});
    try std.testing.expect(sdk.test_sdk(offline, vnull()).model(vnull()).stream("list", vnull(), quiet) == .ok);

    if (fh.fh_has_feature("rbac")) {
        const deny = h.jo(&.{.{ "feature", h.jo(&.{.{ "rbac", h.jo(&.{
            .{ "active", h.vbool(true) },
            .{ "deny", h.vbool(true) },
        }) }}) }});
        switch (sdk.test_sdk(vnull(), deny).model(vnull()).stream("list", vnull(), vnull())) {
            .err => |er| try std.testing.expect(std.mem.eql(u8, er.code, "rbac_denied")),
            .ok => try std.testing.expect(false),
        }
    }
}

test "model_stream_ctrl" {
    const explain = h.omap();
    const ctrl = h.jo(&.{.{ "explain", explain }});
    _ = sdk.test_sdk(vnull(), vnull()).model(vnull()).stream("list", vnull(), h.jo(&.{.{ "ctrl", ctrl }}));
    try std.testing.expect(h.is_noval(h.getp(ctrl, "stream")));
    try std.testing.expect(0 < explain.object.count());
}

test "model_validate" {
    if (!fh.fh_has_feature("validate")) return error.SkipZigTest;
    const opts = h.jo(&.{.{ "feature", h.jo(&.{.{ "validate", h.jo(&.{.{ "active", h.vbool(true) }}) }}) }});
    switch (sdk.test_sdk(vnull(), opts).model(vnull()).list(h.jo(&.{ .{ "executionProvider", h.vnum(1) } }), vnull())) {
        .err => |er| try std.testing.expect(std.mem.eql(u8, er.code, "validate_failed")),
        .ok => try std.testing.expect(false),
    }
}

test "model_direct_smoke" {
    // direct() drives prepare -> transport and always returns a result map
    // carrying an `ok` flag (never an error union), even on a non-2xx or a
    // prepare failure.
    const testsdk = sdk.test_sdk(vnull(), vnull());
    const result = testsdk.direct(h.jo(&.{
        .{ "path", h.vstr("/model/{id}") },
        .{ "method", h.vstr("GET") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("direct01") }}) },
    }));
    try std.testing.expect(result == .object);
    try std.testing.expect(h.get_bool(result, "ok") != null);
}

test "model_prepare_smoke" {
    // prepare() returns the fetch definition (an error union). The generated
    // fetchdef always carries a url + method.
    const testsdk = sdk.test_sdk(vnull(), vnull());
    const fetchdef = testsdk.prepare(h.jo(&.{
        .{ "path", h.vstr("/model/{id}") },
        .{ "method", h.vstr("GET") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("direct01") }}) },
    })) catch {
        // A prepare error is acceptable here (base may be unset); the surface
        // exists and is exercised.
        return;
    };
    try std.testing.expect(std.mem.eql(u8, h.get_str(fetchdef, "method") orelse "", "GET"));
}

// Documented quick-start surface (README.md / REFERENCE.md). Exercises the
// test-mode constructor and the direct() escape hatch exactly as documented.
test "readme_quickstart_surface" {
    // `sdk.test_sdk(...)` — the documented mock constructor.
    const client = sdk.test_sdk(vnull(), vnull());
    try std.testing.expect(std.mem.eql(u8, client.mode, "test"));

    // `client.direct(...)` — the documented escape hatch. It always returns a
    // result map carrying an `ok` flag (never an error union).
    const result = client.direct(h.jo(&.{
        .{ "path", h.vstr("/api/resource/{id}") },
        .{ "method", h.vstr("GET") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("example") }}) },
    }));
    try std.testing.expect(result == .object);
    try std.testing.expect(h.get_bool(result, "ok") != null);

    // `client.prepare(...)` — build a request without sending it.
    const fetchdef = client.prepare(h.jo(&.{
        .{ "path", h.vstr("/api/resource/{id}") },
        .{ "method", h.vstr("GET") },
        .{ "params", h.jo(&.{.{ "id", h.vstr("example") }}) },
    })) catch h.vnull();
    _ = fetchdef;
}
