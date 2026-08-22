// Per-call control state (mirrors go core/control.go).

const h = @import("helpers.zig");
const err = @import("error.zig");
const Value = h.Value;

pub const Control = struct {
    throw: ?bool = null,
    err: ?*err.UnivecError = null,
    // explain / paging are Value maps when supplied (.null otherwise). They
    // are the caller's own maps (reference-shared), so recorded entries are
    // visible to the caller after the operation completes.
    explain: Value = .{ .null = {} },
    actor: []const u8 = "",
    paging: Value = .{ .null = {} },

    pub fn make() *Control {
        const c = h.A().create(Control) catch unreachable;
        c.* = .{};
        return c;
    }

    pub fn has_explain(self: *const Control) bool {
        return self.explain == .object;
    }
};
