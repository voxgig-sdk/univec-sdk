// Request specification (mirrors go core/spec.go).

const std = @import("std");
const h = @import("helpers.zig");
const Value = h.Value;

pub const Spec = struct {
    parts: Value = .{ .null = {} },
    headers: Value,
    alias: Value,
    base: []const u8 = "",
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    params: Value,
    query: Value,
    step: []const u8 = "",
    method: []const u8 = "GET",
    body: Value = .{ .null = {} },
    url: []const u8 = "",
    path: []const u8 = "",
    // The query parameters prepare_auth placed: the credential, which the
    // request sends and the entity's match leaves out.
    authquery: []const []const u8 = &.{},

    pub fn make(specmap: Value) *Spec {
        const s = h.A().create(Spec) catch unreachable;
        s.* = .{
            .parts = h.vnull(),
            .headers = h.omap(),
            .alias = h.omap(),
            .params = h.omap(),
            .query = h.omap(),
            .body = h.vnull(),
        };

        if (specmap != .object) return s;

        if (h.getp(specmap, "parts") == .array) s.parts = h.getp(specmap, "parts");
        if (h.getp(specmap, "headers") == .object) s.headers = h.getp(specmap, "headers");
        if (h.getp(specmap, "alias") == .object) s.alias = h.getp(specmap, "alias");
        if (h.get_str(specmap, "base")) |b| s.base = b;
        if (h.get_str(specmap, "prefix")) |p| s.prefix = p;
        if (h.get_str(specmap, "suffix")) |sf| s.suffix = sf;
        if (h.getp(specmap, "params") == .object) s.params = h.getp(specmap, "params");
        if (h.getp(specmap, "query") == .object) s.query = h.getp(specmap, "query");
        if (h.get_str(specmap, "step")) |st| s.step = st;
        if (h.get_str(specmap, "method")) |m| s.method = m;
        const body = h.getp(specmap, "body");
        if (!h.is_noval(body)) s.body = body;
        if (h.get_str(specmap, "url")) |u| s.url = u;
        if (h.get_str(specmap, "path")) |p| s.path = p;

        return s;
    }

    // Whatever prepare_auth set in the query, under whichever name, is the
    // credential; a key it left as it was is the caller's.
    pub fn note_authquery(self: *Spec, before: Value) void {
        var out: std.ArrayList([]const u8) = .empty;
        if (self.query == .object) {
            var it = self.query.object.iterator();
            while (it.next()) |kv| {
                const was = h.getp(before, kv.key_ptr.*);
                if (h.is_noval(was) or !h.veq(was, kv.value_ptr.*)) {
                    out.append(h.A(), kv.key_ptr.*) catch {};
                }
            }
        }
        self.authquery = out.toOwnedSlice(h.A()) catch &.{};
    }

    pub fn authquery_has(self: *const Spec, key: []const u8) bool {
        for (self.authquery) |name| {
            if (std.mem.eql(u8, name, key)) return true;
        }
        return false;
    }

    pub fn to_value(self: *const Spec) Value {
        const out = h.omap();
        h.setp(out, "base", h.vstr(self.base));
        h.setp(out, "prefix", h.vstr(self.prefix));
        h.setp(out, "suffix", h.vstr(self.suffix));
        h.setp(out, "path", h.vstr(self.path));
        h.setp(out, "method", h.vstr(self.method));
        h.setp(out, "params", self.params);
        h.setp(out, "query", self.query);
        h.setp(out, "headers", self.headers);
        h.setp(out, "step", h.vstr(self.step));
        h.setp(out, "alias", self.alias);
        if (!h.is_noval(self.body)) h.setp(out, "body", self.body);
        if (self.url.len != 0) h.setp(out, "url", h.vstr(self.url));
        return out;
    }
};
