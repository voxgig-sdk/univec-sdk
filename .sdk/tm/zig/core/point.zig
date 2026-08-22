// Endpoint point description (mirrors go core/target.go NewPoint). Points
// stay Value maps in the pipeline; this typed view is a convenience.

const h = @import("helpers.zig");
const Value = h.Value;

pub const Point = struct {
    args: Value,
    rename: Value,
    method: []const u8 = "",
    orig: []const u8 = "",
    parts: Value,
    params: Value,
    select: Value,
    // Absent in config means ACTIVE: emission drops `active: true` as a default (sdkgen L0), so only an explicit `active: false` turns a point off.
    active: bool = true,
    relations: Value,
    alias: Value,
    transform: Value,

    pub fn make(altmap: Value) *Point {
        const p = h.A().create(Point) catch unreachable;

        const args: Value = switch (h.to_map(h.getp(altmap, "args"))) {
            .object => h.to_map(h.getp(altmap, "args")),
            else => h.jo(&.{.{ "params", h.olist() }}),
        };
        const rename: Value = switch (h.to_map(h.getp(altmap, "rename"))) {
            .object => h.to_map(h.getp(altmap, "rename")),
            else => h.jo(&.{.{ "params", h.omap() }}),
        };
        const parts: Value = switch (h.getp(altmap, "parts")) {
            .array => h.getp(altmap, "parts"),
            else => h.olist(),
        };
        const params: Value = switch (h.getp(altmap, "params")) {
            .array => h.getp(altmap, "params"),
            else => h.vnull(),
        };
        const alias: Value = switch (h.to_map(h.getp(altmap, "alias"))) {
            .object => h.to_map(h.getp(altmap, "alias")),
            else => h.omap(),
        };
        const transform: Value = switch (h.to_map(h.getp(altmap, "transform"))) {
            .object => h.to_map(h.getp(altmap, "transform")),
            else => h.omap(),
        };

        p.* = .{
            .args = args,
            .rename = rename,
            .method = h.get_str(altmap, "method") orelse "",
            .orig = h.get_str(altmap, "orig") orelse "",
            .parts = parts,
            .params = params,
            .select = h.to_map(h.getp(altmap, "select")),
            .active = h.get_bool(altmap, "active") orelse false,
            .relations = h.getp(altmap, "relations"),
            .alias = alias,
            .transform = transform,
        };
        return p;
    }
};
