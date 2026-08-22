// Operation result (mirrors go core/result.go).

const h = @import("helpers.zig");
const err = @import("error.zig");
const Value = h.Value;

// Stream producer attached by the streaming feature: yields result items
// (or chunked batches) with configured pacing applied.
pub const StreamFn = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) []Value,
};

pub const SdkResult = struct {
    ok: bool = false,
    status: i64 = -1,
    status_text: []const u8 = "",
    headers: Value,
    body: Value = .{ .null = {} },
    err: ?*err.UnivecError = null,
    resdata: Value = .{ .null = {} },
    resmatch: Value = .{ .null = {} },

    // Feature extensions.
    paging: Value = .{ .null = {} },
    streaming: bool = false,
    stream: ?StreamFn = null,

    pub fn make(resmap: Value) *SdkResult {
        const r = h.A().create(SdkResult) catch unreachable;
        const status: i64 = switch (h.getp(resmap, "status")) {
            .null => -1,
            else => |s| h.to_int(s),
        };
        const headers: Value = switch (h.getp(resmap, "headers")) {
            .object => h.getp(resmap, "headers"),
            else => h.omap(),
        };
        const resmatch: Value = switch (h.getp(resmap, "resmatch")) {
            .object => h.getp(resmap, "resmatch"),
            else => h.vnull(),
        };
        r.* = .{
            .ok = h.get_bool(resmap, "ok") orelse false,
            .status = status,
            .status_text = h.get_str(resmap, "statusText") orelse "",
            .headers = headers,
            .body = h.getp(resmap, "body"),
            .err = null,
            .resdata = h.getp(resmap, "resdata"),
            .resmatch = resmatch,
        };
        return r;
    }

    pub fn to_value(self: *const SdkResult) Value {
        const out = h.omap();
        h.setp(out, "ok", h.vbool(self.ok));
        h.setp(out, "status", h.vnum(self.status));
        h.setp(out, "statusText", h.vstr(self.status_text));
        h.setp(out, "headers", self.headers);
        if (!h.is_noval(self.body)) h.setp(out, "body", self.body);
        if (self.err) |e| {
            const em = h.omap();
            h.setp(em, "message", h.vstr(e.msg));
            h.setp(out, "err", em);
        }
        if (!h.is_noval(self.resdata)) h.setp(out, "resdata", self.resdata);
        if (!h.is_noval(self.resmatch)) h.setp(out, "resmatch", self.resmatch);
        if (!h.is_noval(self.paging)) h.setp(out, "paging", self.paging);
        return out;
    }
};
