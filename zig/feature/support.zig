// Shared option readers for the feature implementations (mirrors go
// feature/feature_options.go / rust feature/support.rs). Feature options
// arrive as Value maps; callables (clocks, sleepers, generators) arrive as
// function values. Zig has no closures, so the injectable clock/sleep are
// plain functions taking the options (and the arg) rather than returning a
// closure.

const std = @import("std");
const h = @import("../core/helpers.zig");
const Value = h.Value;

pub fn fopt_bool(options: Value, key: []const u8, def: bool) bool {
    return switch (h.getp(options, key)) {
        .bool => |b| b,
        else => def,
    };
}

pub fn fopt_int(options: Value, key: []const u8, def: i64) i64 {
    return switch (h.getp(options, key)) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => def,
    };
}

pub fn fopt_num(options: Value, key: []const u8, def: f64) f64 {
    return switch (h.getp(options, key)) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => def,
    };
}

pub fn fopt_str(options: Value, key: []const u8, def: []const u8) []const u8 {
    return switch (h.getp(options, key)) {
        .string => |s| if (s.len != 0) s else def,
        else => def,
    };
}

pub fn fopt_map(options: Value, key: []const u8) Value {
    return switch (h.getp(options, key)) {
        .object => h.getp(options, key),
        else => h.vnull(),
    };
}

pub fn fopt_list(options: Value, key: []const u8) Value {
    return switch (h.getp(options, key)) {
        .array => h.getp(options, key),
        else => h.vnull(),
    };
}

pub fn fopt_str_list(options: Value, key: []const u8) ?[][]const u8 {
    const l = h.getp(options, key);
    if (l != .array) return null;
    var out = std.ArrayList([]const u8).init(h.A());
    for (l.array.data.items) |v| {
        if (v == .string) out.append(v.string) catch {};
    }
    return out.toOwnedSlice() catch &.{};
}

// The injectable sleep (option "sleep": a function taking ms), defaulting to
// a real thread sleep.
pub fn fopt_sleep(options: Value, ms: i64) void {
    const f = h.getp(options, "sleep");
    if (f == .function) {
        _ = h.call_vfn(f, h.vnum(ms));
    } else if (ms > 0) {
        h.sleep_ms(ms);
    }
}

// The injectable clock (option "now": a function -> ms), defaulting to the
// wall clock.
pub fn fopt_now(options: Value) i64 {
    const f = h.getp(options, "now");
    if (f == .function) return h.to_int(h.call_vfn(f, h.vnull()));
    return h.now_ms();
}

// Read a header value case-insensitively.
pub fn fheader_get(headers: Value, name: []const u8) ?Value {
    if (headers == .object) {
        var it = headers.object.iterator();
        while (it.next()) |kv| {
            if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) return kv.value_ptr.*;
        }
    }
    return null;
}

// Set a header only when no case-insensitive variant exists already.
pub fn fheader_set_default(headers: Value, name: []const u8, value: []const u8) void {
    if (headers != .object) return;
    if (fheader_get(headers, name) != null) return;
    h.setp(headers, name, h.vstr(value));
}

// The numeric status from a transport-shaped response map.
pub fn fres_status(res: Value) ?i64 {
    return switch (h.getp(res, "status")) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

// Read a header from a transport-shaped response, case-insensitively.
pub fn fres_header(res: Value, name: []const u8) ?[]const u8 {
    const headers = h.getp(res, "headers");
    if (headers != .object) return null;
    if (fheader_get(headers, name)) |v| {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
    return null;
}

pub fn fparse_int(s: []const u8, def: i64) i64 {
    const t = std.mem.trim(u8, s, " \t");
    return std.fmt.parseInt(i64, t, 10) catch def;
}
