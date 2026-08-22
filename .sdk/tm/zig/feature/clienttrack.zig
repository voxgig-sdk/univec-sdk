// Client tracking (mirrors go feature/clienttrack_feature.go / rust
// feature/clienttrack.rs). Establishes a stable per-client session id at
// construction and stamps identifying headers on every request: a `User-Agent`
// (`<clientName>/<clientVersion>`), an `X-Client-Id` (session), and a fresh
// per-request `X-Request-Id`. Header names, client name/version and the id
// generator (`idgen`) are configurable; caller-provided User-Agent /
// X-Client-Id values are never clobbered.

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;

pub const ClienttrackFeature = struct {
    name: []const u8 = "clienttrack",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },

    // Activity tracking (mirrors the ts client._clienttrack record).
    session: []const u8 = "",
    requests: i64 = 0,
    last_request_id: []const u8 = "",
    client_name: []const u8 = "",

    pub fn make() Feature {
        const self = h.A().create(ClienttrackFeature) catch unreachable;
        self.* = .{};
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *ClienttrackFeature {
        return @ptrCast(@alignCast(p));
    }

    fn full_name(self: *ClienttrackFeature) []const u8 {
        const name = sup.fopt_str(self.options, "clientName", "Univec-SDK");
        const version = sup.fopt_str(self.options, "clientVersion", "0.0.1");
        return std.fmt.allocPrint(h.A(), "{s}/{s}", .{ name, version }) catch name;
    }

    fn genid(self: *ClienttrackFeature, kind: []const u8) []const u8 {
        const idgen = h.getp(self.options, "idgen");
        if (idgen == .function) {
            const r = h.call_vfn(idgen, h.vstr(kind));
            if (r == .string) return r.string;
        }
        const raw = std.fmt.allocPrint(h.A(), "{s}-{x:0>6}{x:0>6}{x:0>6}", .{
            kind[0..1],
            @as(u32, @intCast(h.rand_int(0x1000000))),
            @as(u32, @intCast(h.rand_int(0x1000000))),
            @as(u32, @intCast(h.rand_int(0x1000000))),
        }) catch "";
        return if (raw.len > 20) raw[0..20] else raw;
    }

    fn post_construct(self: *ClienttrackFeature, ctx: *Context) void {
        _ = ctx;
        if (!self.active) return;
        const sid = sup.fopt_str(self.options, "sessionId", "");
        self.session = if (sid.len == 0) self.genid("session") else sid;
        self.client_name = self.full_name();
    }

    fn pre_request(self: *ClienttrackFeature, ctx: *Context) void {
        if (!self.active) return;

        const sp = ctx.spec orelse return;
        const headers: Value = if (sp.headers == .object) sp.headers else blk: {
            const nh = h.omap();
            sp.headers = nh;
            break :blk nh;
        };

        // Lazily establish the session when PostConstruct never fired.
        if (self.session.len == 0) {
            const sid = sup.fopt_str(self.options, "sessionId", "");
            self.session = if (sid.len == 0) self.genid("session") else sid;
        }

        const hmap = sup.fopt_map(self.options, "headers");
        self.requests += 1;
        const request_id = self.genid("request");

        sup.fheader_set_default(headers, sup.fopt_str(hmap, "agent", "User-Agent"), self.full_name());
        sup.fheader_set_default(headers, sup.fopt_str(hmap, "client", "X-Client-Id"), self.session);
        h.setp(headers, sup.fopt_str(hmap, "request", "X-Request-Id"), h.vstr(request_id));

        self.last_request_id = request_id;
        self.client_name = self.full_name();
    }

    fn vname(p: *anyopaque) []const u8 {
        return self_of(p).name;
    }
    fn vactive(p: *anyopaque) bool {
        return self_of(p).active;
    }
    fn vaddopts(p: *anyopaque) Value {
        return self_of(p).add_opts;
    }
    fn vinit(p: *anyopaque, ctx: *Context, options: Value) void {
        _ = ctx;
        const self = self_of(p);
        self.options = options;
        self.active = sup.fopt_bool(options, "active", false);
        self.requests = 0;
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        const self = self_of(p);
        if (std.mem.eql(u8, name, "PostConstruct")) {
            self.post_construct(ctx);
        } else if (std.mem.eql(u8, name, "PreRequest")) {
            self.pre_request(ctx);
        }
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};
