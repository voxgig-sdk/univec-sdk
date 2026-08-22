// Transport response wrapper (mirrors go core/response.go). The `json` entry
// stays a function thunk so bodies can be re-read repeatedly.

const h = @import("helpers.zig");
const err = @import("error.zig");
const Value = h.Value;

pub const Response = struct {
    status: i64 = -1,
    status_text: []const u8 = "",
    headers: Value = .{ .null = {} },
    json: Value = .{ .null = {} },
    body: Value = .{ .null = {} },
    err: ?*err.UnivecError = null,

    pub fn make(resmap: Value) *Response {
        const r = h.A().create(Response) catch unreachable;
        const status: i64 = switch (h.getp(resmap, "status")) {
            .null => -1,
            else => |s| h.to_int(s),
        };
        r.* = .{
            .status = status,
            .status_text = h.get_str(resmap, "statusText") orelse "",
            .headers = h.getp(resmap, "headers"),
            .json = h.getp(resmap, "json"),
            .body = h.getp(resmap, "body"),
            .err = null,
        };
        return r;
    }
};
