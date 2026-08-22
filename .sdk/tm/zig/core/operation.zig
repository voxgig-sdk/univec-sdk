// Operation description (mirrors go core/operation.go).

const h = @import("helpers.zig");
const Value = h.Value;

pub const Operation = struct {
    entity: []const u8 = "_",
    name: []const u8 = "_",
    input: []const u8 = "_",
    points: Value,
    alias: Value,

    pub fn make(opmap: Value) *Operation {
        const o = h.A().create(Operation) catch unreachable;

        const entity = h.get_str(opmap, "entity");
        const name = h.get_str(opmap, "name");
        const input = h.get_str(opmap, "input");

        const points: Value = switch (h.getp(opmap, "points")) {
            .array => h.getp(opmap, "points"),
            else => h.olist(),
        };

        o.* = .{
            .entity = if (entity) |e| (if (e.len == 0) "_" else e) else "_",
            .name = if (name) |n| (if (n.len == 0) "_" else n) else "_",
            .input = if (input) |i| (if (i.len == 0) "_" else i) else "_",
            .points = points,
            .alias = h.to_map(h.getp(opmap, "alias")),
        };
        return o;
    }
};
