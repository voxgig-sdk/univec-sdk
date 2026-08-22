// Outbound HTTP(S) proxy support (mirrors go feature/proxy_feature.go / rust
// feature/proxy.rs). Wraps the active transport and annotates each request's
// fetch definition with the proxy target (`fetchdef.proxy`). The default
// transport honours the annotation by routing the request through an agent
// configured with that proxy; custom transports can do the same. The proxy
// target comes from options (`url`) or, when `fromEnv` is set, the standard
// HTTPS_PROXY / HTTP_PROXY / NO_PROXY environment variables. Hosts matching
// `noProxy` bypass the proxy.

const std = @import("std");
const h = @import("../core/helpers.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;

pub const ProxyTrack = struct {
    // Activity tracking (mirrors the ts client._proxy record).
    routed: i64 = 0,
    url: []const u8 = "",
    no_proxy: []const []const u8 = &.{},
};

pub const ProxyFeature = struct {
    name: []const u8 = "proxy",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    track: *ProxyTrack,

    pub fn make() Feature {
        const self = h.A().create(ProxyFeature) catch unreachable;
        const track = h.A().create(ProxyTrack) catch unreachable;
        track.* = .{};
        self.* = .{ .track = track };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
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
        const self = self_of(p);
        self.options = options;
        self.active = sup.fopt_bool(options, "active", false);
        if (!self.active) return;

        var url = sup.fopt_str(options, "url", "");
        var no_proxy_opt = sup.fopt_str_list(options, "noProxy");

        if (sup.fopt_bool(options, "fromEnv", false)) {
            if (url.len == 0) {
                url = first_env(&.{ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy" });
            }
            if (no_proxy_opt == null) {
                const np = first_env(&.{ "NO_PROXY", "no_proxy" });
                if (np.len != 0) {
                    var list = std.ArrayList([]const u8).init(h.A());
                    var it = std.mem.splitScalar(u8, np, ',');
                    while (it.next()) |s| list.append(s) catch {};
                    no_proxy_opt = list.toOwnedSlice() catch null;
                }
            }
        }

        var np_list = std.ArrayList([]const u8).init(h.A());
        if (no_proxy_opt) |arr| {
            for (arr) |s| {
                const trimmed = std.mem.trim(u8, s, " \t\r\n");
                if (trimmed.len != 0) np_list.append(trimmed) catch {};
            }
        }
        const no_proxy: []const []const u8 = np_list.toOwnedSlice() catch &.{};

        self.track.url = url;
        self.track.no_proxy = no_proxy;

        const util = ctx.util();
        const w = h.A().create(WrapCtx) catch unreachable;
        w.* = .{ .inner = util.fetcher, .track = self.track };
        util.fetcher = .{ .ctx = @ptrCast(w), .call = wrapCall };
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        _ = p;
        _ = name;
        _ = ctx;
    }

    fn self_of(p: *anyopaque) *ProxyFeature {
        return @ptrCast(@alignCast(p));
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};

const WrapCtx = struct {
    inner: Fetcher,
    track: *ProxyTrack,
};

fn wrapCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *WrapCtx = @ptrCast(@alignCast(p));
    const routed = route(w.track, url, fetchdef);
    return w.inner.invoke(ctx, url, routed);
}

fn first_env(names: []const []const u8) []const u8 {
    for (names) |name| {
        if (std.process.getEnvVarOwned(h.A(), name)) |v| {
            if (v.len != 0) return v;
        } else |_| {}
    }
    return "";
}

fn host_of(url: []const u8) []const u8 {
    // <scheme>://<host>[:port][/...]
    var rest = url;
    if (std.mem.indexOf(u8, url, "://")) |i| {
        rest = url[i + 3 ..];
    }
    var end = rest.len;
    for (rest, 0..) |c, idx| {
        if (c == '/' or c == ':') {
            end = idx;
            break;
        }
    }
    return rest[0..end];
}

fn bypass(no_proxy: []const []const u8, url: []const u8) bool {
    if (no_proxy.len == 0) return false;
    const host = host_of(url);
    for (no_proxy) |np| {
        if (std.mem.eql(u8, np, "*")) return true;
        const np_trim = std.mem.trimLeft(u8, np, ".");
        if (std.mem.eql(u8, host, np)) return true;
        const suffix = std.fmt.allocPrint(h.A(), ".{s}", .{np_trim}) catch continue;
        if (std.mem.endsWith(u8, host, suffix)) return true;
    }
    return false;
}

fn route(track: *ProxyTrack, url: []const u8, fetchdef: Value) Value {
    const proxy_url = track.url;
    const no_proxy = track.no_proxy;

    if (proxy_url.len == 0 or bypass(no_proxy, url)) {
        return fetchdef;
    }

    const out = h.omap();
    if (fetchdef == .object) {
        var it = fetchdef.object.iterator();
        while (it.next()) |kv| {
            h.setp(out, kv.key_ptr.*, kv.value_ptr.*);
        }
    }
    h.setp(out, "proxy", h.vstr(proxy_url));

    track.routed += 1;
    return out;
}
