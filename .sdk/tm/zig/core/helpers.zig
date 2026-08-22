// Shared Value helpers for the Univec SDK pipeline. The SDK data model
// is the vendored voxgig struct `JsonValue` (utility/voxgigstruct) — the
// JSON-shaped, reference-stable (*MapRef / *ListRef) node used for ctx data,
// specs, options, transport payloads and results, exactly as the Go SDK
// passes map[string]any around. `.null` doubles as "absent" (Group A rule),
// so is_noval and is_null are the same test here.

const std = @import("std");
const vs = @import("voxgig-struct");
const mem = @import("mem.zig");
const err = @import("error.zig");

pub const Value = vs.JsonValue;
pub const Allocator = std.mem.Allocator;
pub const SdkError = err.UnivecError;
pub const E = err.E;

pub fn A() Allocator {
    return mem.a();
}

// ---- constructors ------------------------------------------------------

pub fn vstr(s: []const u8) Value {
    return .{ .string = s };
}
pub fn vnum(n: i64) Value {
    return .{ .integer = n };
}
pub fn vfloat(n: f64) Value {
    return .{ .float = n };
}
pub fn vbool(b: bool) Value {
    return .{ .bool = b };
}
pub fn vnull() Value {
    return .{ .null = {} };
}
pub fn omap() Value {
    return Value.makeMap(A()) catch unreachable;
}
pub fn olist() Value {
    return Value.makeList(A()) catch unreachable;
}

// ---- predicates --------------------------------------------------------

pub fn is_null(v: Value) bool {
    return v == .null;
}
pub fn is_noval(v: Value) bool {
    return v == .null;
}
pub fn ismap(v: Value) bool {
    return v == .object;
}
pub fn islist(v: Value) bool {
    return v == .array;
}
pub fn isfunc(v: Value) bool {
    return v == .function;
}

// ---- struct wrappers (allocator-first, error-swallowing) ---------------

pub fn clone(v: Value) Value {
    return vs.clone(A(), v) catch v;
}
pub fn sizeOf(v: Value) i64 {
    return vs.size(v);
}
pub fn typify(v: Value) i64 {
    return vs.typify(v);
}
pub fn is_empty(v: Value) bool {
    return vs.isempty(v);
}
pub fn get_elem(v: Value, key: Value, alt: Value) Value {
    return vs.getelem(A(), v, key, alt) catch alt;
}
pub fn esc_re(s: []const u8) []const u8 {
    return vs.escre(A(), s) catch s;
}
pub fn esc_url(s: []const u8) []const u8 {
    return vs.escurl(A(), s) catch s;
}
pub fn jsonify_compact(v: Value) []const u8 {
    return vs.jsonifyCompact(A(), v) catch "";
}
pub fn merge(v: Value) Value {
    return vs.merge(A(), v, vs.MAXDEPTH) catch v;
}

// JS String()-style scalar rendering for URL params / keys.
pub fn scalar_str(v: Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(A(), "{d}", .{i}) catch "",
        .float => |f| std.fmt.allocPrint(A(), "{d}", .{f}) catch "",
        .bool => |b| if (b) "true" else "false",
        else => vs.stringify(A(), v, null) catch "",
    };
}

pub fn stringify(v: Value) []const u8 {
    return vs.stringify(A(), v, null) catch "";
}

// ---- property / path access --------------------------------------------

// Property read: getp(map, "key") — .null when absent (mirrors GetProp).
pub fn getp(val: Value, key: []const u8) Value {
    return vs.getprop(A(), val, vstr(key), vnull()) catch vnull();
}

// Property write (no-op when val is not a map). Direct map put so an explicit
// null value is stored (not treated as a delete), and the key is duped onto
// the arena so temp-buffer keys stay valid.
pub fn setp(val: Value, key: []const u8, newval: Value) void {
    switch (val) {
        .object => |m| {
            const k = A().dupe(u8, key) catch key;
            m.put(k, newval) catch {};
        },
        else => {},
    }
}

// Path read on a Value store.
pub fn getpath(path: []const []const u8, store: Value) Value {
    const pl = Value.makeList(A()) catch unreachable;
    for (path) |seg| pl.array.append(vstr(seg)) catch {};
    return vs.getpath(A(), pl, store) catch vnull();
}

// Path write on a Value store. The store's *MapRef nodes are mutated in
// place, so the caller keeps using the ROOT (never rebinds to the return —
// gotcha #8). We discard the return here for exactly that reason.
pub fn setpath(store: Value, path: []const []const u8, val: Value) void {
    const pl = Value.makeList(A()) catch unreachable;
    for (path) |seg| pl.array.append(vstr(seg)) catch {};
    _ = vs.setpath(A(), store, pl, val) catch {};
}

pub fn del_prop(parent: Value, key: Value) void {
    _ = vs.delprop(A(), parent, key) catch {};
}

// ---- literal builders --------------------------------------------------

pub const Pair = struct { []const u8, Value };

pub fn jo(pairs: []const Pair) Value {
    const m = omap();
    for (pairs) |p| setp(m, p[0], p[1]);
    return m;
}

pub fn ja(vals: []const Value) Value {
    const l = olist();
    for (vals) |it| l.array.append(it) catch {};
    return l;
}

// ---- coercions ---------------------------------------------------------

pub fn to_map(v: Value) Value {
    return if (v == .object) v else vnull();
}

pub fn to_int(v: Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => -1,
    };
}

pub fn get_str(m: Value, key: []const u8) ?[]const u8 {
    return switch (getp(m, key)) {
        .string => |s| s,
        else => null,
    };
}
pub fn get_bool(m: Value, key: []const u8) ?bool {
    return switch (getp(m, key)) {
        .bool => |b| b,
        else => null,
    };
}
pub fn get_i64(m: Value, key: []const u8) ?i64 {
    return switch (getp(m, key)) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}
pub fn get_f64(m: Value, key: []const u8) ?f64 {
    return switch (getp(m, key)) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

// ---- deep equality (mirrors the rust Value PartialEq) ------------------

fn numOf(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn veq(x: Value, y: Value) bool {
    if (numOf(x)) |xn| {
        if (numOf(y)) |yn| return xn == yn;
    }
    return switch (x) {
        .null => y == .null,
        .bool => |b| y == .bool and y.bool == b,
        .string => |s| y == .string and std.mem.eql(u8, s, y.string),
        .number_string => |s| y == .number_string and std.mem.eql(u8, s, y.number_string),
        .object => |m| blk: {
            if (y != .object) break :blk false;
            const n = y.object;
            if (m.count() != n.count()) break :blk false;
            var it = m.iterator();
            while (it.next()) |kv| {
                const ov = n.get(kv.key_ptr.*) orelse break :blk false;
                if (!veq(kv.value_ptr.*, ov)) break :blk false;
            }
            break :blk true;
        },
        .array => |l| blk: {
            if (y != .array) break :blk false;
            const n = y.array;
            if (l.data.items.len != n.data.items.len) break :blk false;
            for (l.data.items, n.data.items) |a_, b_| {
                if (!veq(a_, b_)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

// ---- key / item vectors (test feature convenience) ---------------------

pub fn keysof_vec(v: Value) [][]const u8 {
    var out = std.ArrayList([]const u8).init(A());
    if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |kv| out.append(kv.key_ptr.*) catch {};
    }
    return out.toOwnedSlice() catch &.{};
}

pub const KVpair = struct { k: []const u8, v: Value };

pub fn items_vec(v: Value) []KVpair {
    var out = std.ArrayList(KVpair).init(A());
    if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |kv| out.append(.{ .k = kv.key_ptr.*, .v = kv.value_ptr.* }) catch {};
    }
    return out.toOwnedSlice() catch &.{};
}

// ---- clocks / rng ------------------------------------------------------

pub fn now_ms() i64 {
    return std.time.milliTimestamp();
}

pub fn sleep_ms(ms: i64) void {
    if (ms > 0) std.time.sleep(@as(u64, @intCast(ms)) * std.time.ns_per_ms);
}

var rand_seed: i64 = 123456789;

pub fn rand_int(n: i64) i64 {
    if (n <= 0) return 0;
    rand_seed = (rand_seed *% 1103515245 +% 12345) & 0x7fffffff;
    return @mod(rand_seed, n);
}

// ---- callables ---------------------------------------------------------

pub const CallFn = *const fn (ctx: *anyopaque, allocator: Allocator, arg: Value) anyerror!Value;

pub fn callable(ctx_ptr: *anyopaque, f: CallFn) Value {
    const c = A().create(vs.Callable) catch unreachable;
    c.* = .{ .ctx = ctx_ptr, .call = f };
    return .{ .function = c };
}

pub fn call_vfn(f: Value, arg: Value) Value {
    return switch (f) {
        .function => |c| c.call(c.ctx, A(), arg) catch vnull(),
        else => vnull(),
    };
}

pub fn call_json(json: Value) Value {
    return call_vfn(json, vnull());
}

const ThunkCtx = struct { data: Value };
fn thunkCall(ctx: *anyopaque, _: Allocator, _: Value) anyerror!Value {
    const tc: *ThunkCtx = @ptrCast(@alignCast(ctx));
    return tc.data;
}

pub fn json_thunk(data: Value) Value {
    const tc = A().create(ThunkCtx) catch unreachable;
    tc.* = .{ .data = data };
    return callable(@ptrCast(tc), thunkCall);
}

// UnsupportedOp error for entity ops the API spec doesn't define.
pub fn unsupported_op(opname: []const u8, entityname: []const u8) *SdkError {
    const msg = std.fmt.allocPrint(A(), "operation '{s}' not supported by entity '{s}'", .{ opname, entityname }) catch "unsupported op";
    return SdkError.make("unsupported_op", msg);
}
