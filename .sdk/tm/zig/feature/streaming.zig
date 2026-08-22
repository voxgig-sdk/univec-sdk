// Streaming result support (mirrors go feature/streaming_feature.go / rust
// feature/streaming.rs, adapted to a synchronous runtime). For list-style
// operations it attaches a `result.stream` producer so callers can consume
// items incrementally instead of materialising the whole list themselves. A
// `chunkSize` groups items into list batches when set; a `chunkDelay` (ms)
// paces delivery via the injectable `sleep` for offline tests.

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");
const result_mod = @import("../core/result.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const StreamFn = result_mod.StreamFn;
const SdkResult = result_mod.SdkResult;

pub const StreamingFeature = struct {
    name: []const u8 = "streaming",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },

    // Activity tracking (mirrors the ts client._streaming record).
    opened: i64 = 0,

    pub fn make() Feature {
        const self = h.A().create(StreamingFeature) catch unreachable;
        self.* = .{};
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *StreamingFeature {
        return @ptrCast(@alignCast(p));
    }

    fn streamable(self: *StreamingFeature, ctx: *Context) bool {
        const opname = ctx.op.name;
        const ops: []const []const u8 = sup.fopt_str_list(self.options, "ops") orelse &[_][]const u8{"list"};
        for (ops) |o| {
            if (std.mem.eql(u8, o, opname)) return true;
        }
        return false;
    }

    fn pre_result(self: *StreamingFeature, ctx: *Context) void {
        if (!self.active or !self.streamable(ctx)) return;
        const result = ctx.result orelse return;

        // The stream producer captures the options plus the result it reads
        // resdata from. (Rust holds a weak Rc to avoid a reference cycle; with
        // arena allocation here a plain pointer is sufficient.)
        const sc = h.A().create(StreamCtx) catch unreachable;
        sc.* = .{ .options = self.options, .result = result };

        result.streaming = true;
        result.stream = StreamFn{ .ctx = @ptrCast(sc), .call = streamCall };

        self.opened += 1;
    }

    fn vname(p: *anyopaque) []const u8 {
        return self_of(p).name;
    }
    fn vactive(p: *anyopaque) bool {
        return self_of(p).active;
    }
    fn vaddopts(p: *anyopaque) Value {
        return self_of(p).add_opts;
    }
    fn vinit(p: *anyopaque, ctx: *Context, options: Value) void {
        _ = ctx;
        const self = self_of(p);
        self.options = options;
        self.active = sup.fopt_bool(options, "active", false);
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        if (std.mem.eql(u8, name, "PreResult")) self_of(p).pre_result(ctx);
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};

const StreamCtx = struct {
    options: Value,
    result: *SdkResult,
};

fn streamCall(p: *anyopaque) []Value {
    const sc: *StreamCtx = @ptrCast(@alignCast(p));
    return iterate(sc.options, sc.result.resdata);
}

fn iterate(options: Value, resdata: Value) []Value {
    const chunk_delay = sup.fopt_int(options, "chunkDelay", 0);
    const chunk_size = sup.fopt_int(options, "chunkSize", 0);

    const items: []const Value = if (resdata == .array) resdata.array.data.items else &[_]Value{};

    var out = std.ArrayList(Value).init(h.A());

    if (chunk_size > 0) {
        const cs: usize = @intCast(chunk_size);
        var i: usize = 0;
        while (i < items.len) {
            if (chunk_delay > 0) sup.fopt_sleep(options, chunk_delay);
            const end = @min(i + cs, items.len);
            out.append(h.ja(items[i..end])) catch {};
            i = end;
        }
        return out.toOwnedSlice() catch &.{};
    }

    for (items) |item| {
        if (chunk_delay > 0) sup.fopt_sleep(options, chunk_delay);
        out.append(item) catch {};
    }
    return out.toOwnedSlice() catch &.{};
}
