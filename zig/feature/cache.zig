// Response caching for safe (read) requests (mirrors go
// feature/cache_feature.go / rust feature/cache.rs). Wraps the active
// transport and serves a fresh cached snapshot instead of hitting the network
// when the same method+URL was fetched within `ttl` ms (default: 5000). Only
// successful (2xx) responses to cacheable methods (default: GET) are stored,
// keyed by method+URL. The cache is bounded (`max` entries, default 256,
// oldest evicted first) and every hit/miss/bypass is counted. Bodies are
// snapshotted on capture so both the current caller and later hits can
// re-read the JSON body repeatedly.

const std = @import("std");
const h = @import("../core/helpers.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;

pub const CacheSnapshot = struct {
    status: i64,
    status_text: []const u8,
    data: Value,
    headers: Value,
};

pub const CacheEntry = struct {
    expiry: i64,
    snapshot: *CacheSnapshot,
};

pub const CacheTrack = struct {
    store: std.StringHashMap(CacheEntry),
    order: std.ArrayList([]const u8),

    // Activity tracking (mirrors the ts client._cache record).
    hit: i64 = 0,
    miss: i64 = 0,
    bypass: i64 = 0,
};

pub const CacheFeature = struct {
    name: []const u8 = "cache",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    track: *CacheTrack,

    pub fn make() Feature {
        const self = h.A().create(CacheFeature) catch unreachable;
        const track = h.A().create(CacheTrack) catch unreachable;
        track.* = .{
            .store = std.StringHashMap(CacheEntry).init(h.A()),
            .order = std.ArrayList([]const u8).init(h.A()),
        };
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

        const util = ctx.util();
        const w = h.A().create(WrapCtx) catch unreachable;
        w.* = .{ .inner = util.fetcher, .options = options, .track = self.track };
        util.fetcher = .{ .ctx = @ptrCast(w), .call = wrapCall };
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        _ = p;
        _ = name;
        _ = ctx;
    }

    fn self_of(p: *anyopaque) *CacheFeature {
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
    options: Value,
    track: *CacheTrack,
};

fn wrapCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
    const w: *WrapCtx = @ptrCast(@alignCast(p));
    return through(w.track, w.options, ctx, url, fetchdef, w.inner);
}

fn upperAlloc(s: []const u8) []const u8 {
    const buf = h.A().alloc(u8, s.len) catch return s;
    return std.ascii.upperString(buf, s);
}

fn lowerAlloc(s: []const u8) []const u8 {
    const buf = h.A().alloc(u8, s.len) catch return s;
    return std.ascii.lowerString(buf, s);
}

fn through(track: *CacheTrack, options: Value, ctx: *Context, url: []const u8, fetchdef: Value, inner: Fetcher) err.E!Value {
    const raw_method = h.get_str(fetchdef, "method") orelse "";
    const method_src = if (raw_method.len == 0) "GET" else raw_method;
    const method = upperAlloc(method_src);

    const methods: []const []const u8 = sup.fopt_str_list(options, "methods") orelse &[_][]const u8{"GET"};
    var cacheable = false;
    for (methods) |m| {
        if (std.ascii.eqlIgnoreCase(m, method)) {
            cacheable = true;
            break;
        }
    }
    if (!cacheable) return inner.invoke(ctx, url, fetchdef);

    const key = std.fmt.allocPrint(h.A(), "{s} {s}", .{ method, url }) catch method;
    const now = sup.fopt_now(options);

    if (track.store.get(key)) |hit| {
        if (hit.expiry > now) {
            const snap = hit.snapshot;
            track.hit += 1;
            return replay(snap);
        }
    }

    if (inner.invoke(ctx, url, fetchdef)) |res| {
        if (storable(res)) {
            const snap = h.A().create(CacheSnapshot) catch unreachable;
            snap.* = snapshot(res);
            const ttl = sup.fopt_int(options, "ttl", 5000);
            evict(track, options);
            track.store.put(key, .{ .expiry = now + ttl, .snapshot = snap }) catch {};
            track.order.append(key) catch {};
            track.miss += 1;
            return replay(snap);
        }
        track.bypass += 1;
        return res;
    } else |e| {
        track.bypass += 1;
        return e;
    }
}

fn storable(res: Value) bool {
    const status = sup.fres_status(res) orelse return false;
    return status >= 200 and status < 300;
}

fn snapshot(res: Value) CacheSnapshot {
    const headers = h.omap();
    const rh = h.getp(res, "headers");
    if (rh == .object) {
        var it = rh.object.iterator();
        while (it.next()) |kv| {
            h.setp(headers, lowerAlloc(kv.key_ptr.*), kv.value_ptr.*);
        }
    }

    return .{
        .status = sup.fres_status(res) orelse 0,
        .status_text = h.get_str(res, "statusText") orelse "",
        .data = h.call_json(h.getp(res, "json")),
        .headers = headers,
    };
}

// replay builds a fresh transport-shaped response so the body stays
// re-readable for every consumer.
fn replay(snap: *CacheSnapshot) Value {
    const headers = h.omap();
    if (snap.headers == .object) {
        var it = snap.headers.object.iterator();
        while (it.next()) |kv| {
            h.setp(headers, kv.key_ptr.*, kv.value_ptr.*);
        }
    }
    return h.jo(&.{
        .{ "status", h.vnum(snap.status) },
        .{ "statusText", h.vstr(snap.status_text) },
        .{ "body", h.vstr("not-used") },
        .{ "json", h.json_thunk(snap.data) },
        .{ "headers", headers },
    });
}

// evict drops oldest entries (FIFO) until the store is under `max`.
fn evict(track: *CacheTrack, options: Value) void {
    const max: usize = @intCast(@max(sup.fopt_int(options, "max", 256), 0));
    while (track.store.count() >= max and track.order.items.len > 0) {
        const oldest = track.order.orderedRemove(0);
        _ = track.store.remove(oldest);
    }
}
