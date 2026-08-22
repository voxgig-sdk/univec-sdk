// JSON text -> voxgig struct Value, via std.json at the boundary then
// fromStdJson (keeps the SDK runtime free of a hand-rolled parser). Used by
// the default live transport; the offline test transport builds Values
// directly.

const std = @import("std");
const vs = @import("voxgig-struct");
const h = @import("../core/helpers.zig");

pub fn json_parse(src: []const u8) !vs.JsonValue {
    const parsed = try std.json.parseFromSlice(std.json.Value, h.A(), src, .{});
    return vs.fromStdJson(h.A(), parsed.value);
}
