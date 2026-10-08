// UnivecError: the SDK error type (mirrors go core/error.go / the rust
// SdkError fragment). The pipeline error discipline is `E!T` (E = error{Sdk})
// with the rich error object stashed on the context's pending_err, then read
// back by makeError. This templated file only needs the project name.

const std = @import("std");
const vs = @import("voxgig-struct");
const mem = @import("mem.zig");
const Value = vs.JsonValue;

pub const UnivecError = struct {
    sdk: []const u8 = "Univec",
    code: []const u8,
    msg: []const u8,
    // Cleaned snapshots attached by makeError (null until then). The context
    // is not on the error at all, so what prints is what makeError cleaned.
    result: Value = .{ .null = {} },
    spec: Value = .{ .null = {} },

    // Heap-allocate a fresh error on the SDK arena (so it can be pointed at
    // from ctx.pending_err / ctrl.err and outlive the call frame).
    pub fn make(code: []const u8, msg: []const u8) *UnivecError {
        const e = mem.a().create(UnivecError) catch unreachable;
        e.* = .{ .sdk = "Univec", .code = code, .msg = msg };
        return e;
    }

    pub fn to_json(self: *const UnivecError) []const u8 {
        const out = Value.makeMap(mem.a()) catch return "{}";
        out.object.put("sdk", .{ .string = self.sdk }) catch {};
        out.object.put("code", .{ .string = self.code }) catch {};
        out.object.put("msg", .{ .string = self.msg }) catch {};
        out.object.put("result", self.result) catch {};
        out.object.put("spec", self.spec) catch {};
        return vs.jsonifyCompact(mem.a(), out) catch "{}";
    }

    pub fn to_string(self: *const UnivecError) []const u8 {
        const spec = vs.jsonifyCompact(mem.a(), self.spec) catch "null";
        return std.fmt.allocPrint(mem.a(), "{s} [{s}] spec={s}", .{ self.msg, self.code, spec }) catch self.msg;
    }

    pub fn format(self: *const UnivecError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.to_string());
    }
};

// The pipeline error set. The payload travels via ctx.pending_err.
pub const E = error{Sdk};
