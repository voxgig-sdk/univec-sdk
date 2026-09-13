// Univec SDK omni runner smoke test.
//
// Smoke tests for the vendored omni ENGINE itself. A runner that cannot
// FAIL a bad entry turns every corpus suite vacuously green, and a green
// suite that no longer executes the corpus looks exactly like a passing
// one - so the failure paths are pinned here, not just the happy one.
// (Zig peer of ts/test/omni.test.ts, go/test/omnismoke_test.go and
// lua/test/omni_smoke_test.lua.)
//
// The spec is built in memory in omni's own value model, so nothing here
// depends on the compiled corpus.

const std = @import("std");
const testing = std.testing;

const omni = @import("omni");
const R = @import("omniresolver.zig");
const vs = @import("voxgig-struct");

const JsonValue = vs.JsonValue;

// A minimal in-memory spec: no fixture file, no OMNI block (lenient
// version 0, like the shared corpus).
fn makespec(alloc: std.mem.Allocator) !omni.Json {
    const basic = try omni.jmap(alloc, &.{
        .{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{ .{ "in", omni.jnum(1) }, .{ "out", omni.jnum(2) } }),
            try omni.jmap(alloc, &.{ .{ "in", omni.jnum(41) }, .{ "out", omni.jnum(42) } }),
        }) },
    });

    const bad = try omni.jmap(alloc, &.{
        .{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{ .{ "in", omni.jnum(1) }, .{ "out", omni.jnum(999) } }),
        }) },
    });

    const err = try omni.jmap(alloc, &.{
        .{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{ .{ "in", omni.jnum(0) }, .{ "err", omni.jstr("zero refused") } }),
        }) },
    });

    const mutate = try omni.jmap(alloc, &.{
        .{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{
                .{ "in", try omni.jmap(alloc, &.{.{ "n", omni.jnum(1) }}) },
                .{ "match", try omni.jmap(alloc, &.{
                    .{ "args", try omni.jmap(alloc, &.{
                        .{ "0", try omni.jmap(alloc, &.{.{ "n", omni.jnum(9) }}) },
                    }) },
                }) },
                .{ "out", omni.jnum(9) },
            }),
        }) },
    });

    const empty = try omni.jmap(alloc, &.{.{ "set", try omni.jlist(alloc, &.{}) }});

    // An `args` entry whose first argument is a MAP - the one shape the
    // resolver contextifies - and which FAILS. See the test below.
    const ctxfail = try omni.jmap(alloc, &.{
        .{ "set", try omni.jlist(alloc, &.{
            try omni.jmap(alloc, &.{
                .{ "args", try omni.jlist(alloc, &.{
                    try omni.jmap(alloc, &.{
                        .{ "alpha", omni.jstr("one") },
                        .{ "beta", omni.jstr("two") },
                    }),
                    omni.jstr("tag"),
                }) },
                .{ "out", omni.jnum(999) },
            }),
        }) },
    });

    return omni.jmap(alloc, &.{
        .{ "smoke", try omni.jmap(alloc, &.{
            .{ "basic", basic },
            .{ "bad", bad },
            .{ "err", err },
            .{ "mutate", mutate },
            .{ "empty", empty },
            .{ "ctxfail", ctxfail },
        }) },
    });
}

// +1, refusing zero. The corpus numbers arrive as floats through
// std.json, so answer in the same shape.
fn inc(_: std.mem.Allocator, val: JsonValue, errout: *?[]const u8) JsonValue {
    const n: f64 = switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => {
            errout.* = "smoke: not a number";
            return .null;
        },
    };
    if (0 == n) {
        errout.* = "smoke: zero refused";
        return .null;
    }
    return JsonValue{ .float = n + 1 };
}

// The identity, which never raises the error the `err` group expects.
fn same(_: std.mem.Allocator, val: JsonValue, _: *?[]const u8) JsonValue {
    return val;
}

// MUTATES its argument, and answers the new value: the `match: {args: ...}`
// path, which the retired runner could not check at all.
fn bump(_: std.mem.Allocator, val: JsonValue, errout: *?[]const u8) JsonValue {
    if (val != .object) {
        errout.* = "smoke: not a map";
        return .null;
    }
    val.object.put("n", JsonValue{ .float = 9 }) catch {
        errout.* = "smoke: put failed";
        return .null;
    };
    return JsonValue{ .float = 9 };
}

// A ctx-shaped subject that answers a constant and publishes nothing: it
// exists to make an entry FAIL, so the report path can be inspected.
fn constant(
    _: std.mem.Allocator,
    _: []const omni.Json,
    _: *?omni.Json,
    _: *?[]const u8,
) anyerror!omni.Json {
    return omni.jnum(7);
}

// The in-memory spec outlives the runner, so it is built in the test's own
// arena while the runner keeps the leak-checked testing allocator.
fn arenapack(arena: *std.heap.ArenaAllocator) !R.Runner {
    var runner = try R.makeRunnerSpec(
        testing.allocator,
        try makespec(arena.allocator()),
        "smoke",
    );
    runner.quiet = true;
    return runner;
}

test "omni smoke: a correct subject passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    try runner.runseterr(runner.set("basic"), .{}, inc);
}

test "omni smoke: a wrong result FAILS, and says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    try testing.expectError(
        error.CorpusFailure,
        runner.runseterr(runner.set("bad"), .{}, inc),
    );
    try testing.expect(null != runner.failure);
    try testing.expect(null != std.mem.indexOf(u8, runner.failure.?, "result mismatch"));
}

test "omni smoke: an expected error is matched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    try runner.runseterr(runner.set("err"), .{}, inc);
}

test "omni smoke: an expected error that does NOT occur FAILS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    try testing.expectError(
        error.CorpusFailure,
        runner.runseterr(runner.set("err"), .{}, same),
    );
    try testing.expect(null != runner.failure);
    try testing.expect(null != std.mem.indexOf(u8, runner.failure.?, "expected error did not occur"));
}

test "omni smoke: match on a mutated argument is checked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    // The subject that mutates satisfies `match: {args: {0: {n: 9}}}`.
    try runner.runseterr(runner.set("mutate"), .{}, bump);

    // One that does not, fails it - so the write-back is load-bearing, not
    // decorative.
    var second = try arenapack(&arena);
    defer second.deinit();
    try testing.expectError(
        error.CorpusFailure,
        second.runseterr(second.set("mutate"), .{}, same),
    );
    try testing.expect(null != second.failure);
}

test "omni smoke: a failing CONTEXTIFIED entry reports, args and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    // omni contextifies `args[0]` when it is a map, and keeps the AUTHORED
    // `args` list to stringify into the failure report. A contextify that
    // grew that map in place left the report reading the pre-growth entries
    // buffer, which the arena had already handed out again - so a failing
    // entry aborted the binary with a general protection fault instead of
    // naming what differed. Every corpus group of `args` shape goes through
    // this path, and none of them exercise it until they are already red.
    try testing.expectError(
        error.CorpusFailure,
        runner.runsetctx(runner.set("ctxfail"), .{}, constant),
    );
    try testing.expect(null != runner.failure);
    try testing.expect(null != std.mem.indexOf(u8, runner.failure.?, "result mismatch"));
    try testing.expect(null != std.mem.indexOf(u8, runner.failure.?, "\"alpha\":\"one\""));
    try testing.expect(null != std.mem.indexOf(u8, runner.failure.?, "\"beta\":\"two\""));
}

test "omni smoke: an EMPTY set is refused, not passed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    try testing.expectError(
        error.EmptyTestSet,
        runner.runseterr(runner.set("empty"), .{}, inc),
    );
}

test "omni smoke: a group the corpus does not carry is skipped, not invented" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    try testing.expectError(
        error.SkipZigTest,
        runner.runseterr(runner.set("nosuchgroup"), .{}, inc),
    );
}

test "omni smoke: the census counts what actually ran" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    R.resetcensus();

    var runner = try arenapack(&arena);
    defer runner.deinit();

    try runner.runseterr(runner.set("basic"), .{}, inc);
    try testing.expectEqual(@as(usize, 2), R.CASES);
    try testing.expectEqual(@as(usize, 1), R.GROUPS);

    R.resetcensus();
}
