// The Utility bundle + the operation-pipeline builders (mirrors go
// core/utility_type.go + tm/go/utility, and rust core/utility_type.rs +
// utility/*.rs). Go carries the utilities as swappable function pointers;
// here they are free functions, and the two members that genuinely vary per
// client stay swappable: the transport (`fetcher`, wrapped by
// retry/cache/netsim/proxy) and the `custom` map of caller-supplied
// callables.

const std = @import("std");
const vs = @import("voxgig-struct");
const h = @import("helpers.zig");
const err = @import("error.zig");
const types = @import("types.zig");
const ctxmod = @import("context.zig");
const control_mod = @import("control.zig");
const spec_mod = @import("spec.zig");
const response_mod = @import("response.zig");
const result_mod = @import("result.zig");
const operation_mod = @import("operation.zig");
const jsonparse = @import("../utility/jsonparse.zig");
const sdk = @import("sdk.zig");
// The GENERATED option spec make_options validates against. A leaf module
// (it imports only helpers and jsonparse), so this closes no cycle.
const schema = @import("schema.zig");

const Value = h.Value;
const Context = ctxmod.Context;
const CtxSpec = ctxmod.CtxSpec;
const Spec = spec_mod.Spec;
const Response = response_mod.Response;
const SdkResult = result_mod.SdkResult;
const OutVal = types.OutVal;
const Feature = types.Feature;
const Fetcher = types.Fetcher;
const E = err.E;

fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(h.A(), f, args) catch "";
}

// Boolean-or-absent: an option that is unset, null or a non-boolean is false.
fn is_true(v: Value) bool {
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

// ============================================================================
// Utility bundle
// ============================================================================

var fetch_dummy: u8 = 0;

pub const Utility = struct {
    fetcher: Fetcher,
    custom: Value,

    pub fn new() *Utility {
        const u = h.A().create(Utility) catch unreachable;
        u.* = .{
            .fetcher = .{ .ctx = @ptrCast(&fetch_dummy), .call = defaultFetcherCall },
            .custom = h.omap(),
        };
        return u;
    }

    // A fresh view sharing the (possibly feature-wrapped) fetcher, with a
    // shallow copy of the custom map.
    pub fn copy(src: *Utility) *Utility {
        const u = h.A().create(Utility) catch unreachable;
        const custom = h.omap();
        if (src.custom == .object) {
            var it = src.custom.object.iterator();
            while (it.next()) |kv| h.setp(custom, kv.key_ptr.*, kv.value_ptr.*);
        }
        u.* = .{ .fetcher = src.fetcher, .custom = custom };
        return u;
    }

    pub fn fetch(self: *Utility, ctx: *Context, url: []const u8, fetchdef: Value) E!Value {
        return self.fetcher.invoke(ctx, url, fetchdef);
    }

    pub fn clean(self: *Utility, ctx: *Context, val: Value) Value {
        _ = self;
        return clean_util(ctx, val);
    }
    pub fn clean_str(self: *Utility, ctx: *Context, val: []const u8) []const u8 {
        _ = self;
        return clean_str_util(ctx, val);
    }
    pub fn clean_add(self: *Utility, ctx: *Context, value: []const u8) void {
        _ = self;
        clean_add_util(ctx, value);
    }
    pub fn clean_key(self: *Utility, ctx: *Context, key: []const u8) bool {
        _ = self;
        return clean_key_util(ctx, key);
    }
    pub fn done(self: *Utility, ctx: *Context) E!Value {
        _ = self;
        return done_util(ctx);
    }
    pub fn clean_explain(self: *Utility, ctx: *Context) void {
        _ = self;
        clean_explain_util(ctx);
    }
    pub fn make_error(self: *Utility, ctx: *Context) E!Value {
        _ = self;
        return make_error_util(ctx);
    }
    pub fn feature_add(self: *Utility, ctx: *Context, f: Feature) void {
        _ = self;
        feature_add_util(ctx, f);
    }
    pub fn feature_hook(self: *Utility, ctx: *Context, name: []const u8) void {
        _ = self;
        feature_hook_util(ctx, name);
    }
    pub fn feature_init(self: *Utility, ctx: *Context, f: Feature) void {
        _ = self;
        feature_init_util(ctx, f);
    }
    pub fn make_fetch_def(self: *Utility, ctx: *Context) E!Value {
        _ = self;
        return make_fetch_def_util(ctx);
    }
    pub fn make_context(self: *Utility, ctxspec: CtxSpec, basectx: ?*Context) *Context {
        _ = self;
        return Context.new(ctxspec, basectx);
    }
    pub fn make_options(self: *Utility, ctx: *Context) Value {
        _ = self;
        return make_options_util(ctx);
    }
    pub fn make_request(self: *Utility, ctx: *Context) E!*Response {
        _ = self;
        return make_request_util(ctx);
    }
    pub fn make_response(self: *Utility, ctx: *Context) E!*Response {
        _ = self;
        return make_response_util(ctx);
    }
    pub fn make_result(self: *Utility, ctx: *Context) E!*SdkResult {
        _ = self;
        return make_result_util(ctx);
    }
    pub fn make_point(self: *Utility, ctx: *Context) E!Value {
        _ = self;
        return make_point_util(ctx);
    }
    pub fn make_spec(self: *Utility, ctx: *Context) E!*Spec {
        _ = self;
        return make_spec_util(ctx);
    }
    pub fn make_url(self: *Utility, ctx: *Context) E![]const u8 {
        _ = self;
        return make_url_util(ctx);
    }
    pub fn param(self: *Utility, ctx: *Context, paramdef: Value) Value {
        _ = self;
        return param_util(ctx, paramdef);
    }
    pub fn prepare_auth(self: *Utility, ctx: *Context) E!*Spec {
        _ = self;
        return prepare_auth_util(ctx);
    }
    pub fn prepare_headers(self: *Utility, ctx: *Context) Value {
        _ = self;
        return prepare_headers_util(ctx);
    }
};

// ============================================================================
// clean / done / make_error
// ============================================================================

// Everything that leaves the pipeline passes through clean; inside it data
// stays raw, so a hook can still read the header it must add to. The zig
// port of tm/ts/src/utility/CleanUtility.ts. The derived clean block is a
// Value map (`options.__derived__.clean`) whose `values` list is MUTABLE:
// features register secrets after make_options.

const CLEAN_MAXDEPTH: usize = 32;
const CLEAN_CIRCULAR = "[circular]";
// The schema's own default, for a context that reaches clean before any
// options exist.
const CLEAN_DEFAULT_KEYS = "key,secret,token,password,passwd,authorization,cookie,credential,signature";

const CleanCfg = struct {
    active: bool,
    keys: Value,
    values: Value,
    mask: []const u8,
    hint: i64,
    min: i64,
};

fn clean_normkey(key: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (key) |c| {
        if (c == '-' or c == '_') continue;
        out.append(h.A(), std.ascii.toLower(c)) catch {};
    }
    return out.toOwnedSlice(h.A()) catch key;
}

fn clean_count(v: Value, dflt: i64) i64 {
    return switch (v) {
        .integer => |i| if (i >= 0) i else dflt,
        .float => |f| if (f >= 0) @as(i64, @intFromFloat(@floor(f))) else dflt,
        .string => |s| blk: {
            const n = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch break :blk dflt;
            break :blk if (n >= 0) @as(i64, @intFromFloat(@floor(n))) else dflt;
        },
        else => dflt,
    };
}

pub fn make_clean_config(cleanopts: Value) Value {
    const keys_src: []const u8 = switch (h.getp(cleanopts, "keys")) {
        .string => |s| s,
        else => CLEAN_DEFAULT_KEYS,
    };
    const keys = h.olist();
    var it = std.mem.splitScalar(u8, keys_src, ',');
    while (it.next()) |p| {
        const k = clean_normkey(std.mem.trim(u8, p, " \t"));
        if (k.len != 0) keys.array.append(h.vstr(k)) catch {};
    }
    const active = switch (h.getp(cleanopts, "active")) {
        .bool => |b| b,
        else => true,
    };
    const mask: []const u8 = switch (h.getp(cleanopts, "mask")) {
        .string => |s| s,
        else => "[redacted]",
    };
    return h.jo(&.{
        .{ "active", h.vbool(active) },
        .{ "keys", keys },
        .{ "values", h.olist() },
        .{ "mask", h.vstr(mask) },
        .{ "hint", h.vnum(clean_count(h.getp(cleanopts, "hint"), 0)) },
        .{ "min", h.vnum(@max(1, clean_count(h.getp(cleanopts, "min"), 4))) },
    });
}

// The comma-separated `clean.values` option, or a list of strings.
pub fn clean_splitvalues(values: Value) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (values) {
        .array => |l| {
            for (l.data.items) |v| {
                if (v == .string) out.append(h.A(), v.string) catch {};
            }
        },
        .string => |s| {
            var it = std.mem.splitScalar(u8, s, ',');
            while (it.next()) |p| {
                const t = std.mem.trim(u8, p, " \t");
                if (t.len != 0) out.append(h.A(), t) catch {};
            }
        },
        else => {},
    }
    return out.toOwnedSlice(h.A()) catch &.{};
}

// A context without options (make_error accepts a bare one) still masks by
// the schema defaults.
fn clean_config(ctx: *Context) Value {
    const derived = h.getpath(&.{ "__derived__", "clean" }, ctx.options);
    if (derived == .object and h.getp(derived, "values") == .array) return derived;
    return make_clean_config(h.getp(schema.shared_optspec(), "clean"));
}

fn clean_view(cfg: Value) CleanCfg {
    return .{
        .active = h.get_bool(cfg, "active") orelse true,
        .keys = h.getp(cfg, "keys"),
        .values = h.getp(cfg, "values"),
        .mask = h.get_str(cfg, "mask") orelse "[redacted]",
        .hint = h.get_i64(cfg, "hint") orelse 0,
        .min = @max(1, h.get_i64(cfg, "min") orelse 4),
    };
}

fn clean_base64(text: []const u8) []const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = h.A().alloc(u8, enc.calcSize(text.len)) catch return "";
    return enc.encode(buf, text);
}

fn clean_json_escape(text: []const u8) []const u8 {
    const quoted = h.jsonify_compact(h.vstr(text));
    if (quoted.len >= 2 and quoted[0] == '"' and quoted[quoted.len - 1] == '"') {
        return quoted[1 .. quoted.len - 1];
    }
    return text;
}

fn clean_values_has(values: Value, s: []const u8) bool {
    if (values != .array) return false;
    for (values.array.data.items) |v| {
        if (v == .string and std.mem.eql(u8, v.string, s)) return true;
    }
    return false;
}

fn clean_longer_first(_: void, a: Value, b: Value) bool {
    const al: usize = if (a == .string) a.string.len else 0;
    const bl: usize = if (b == .string) b.string.len else 0;
    return al > bl;
}

// Register a value with the encoded forms it travels in.
pub fn clean_add_cfg(cfg: Value, value: []const u8) void {
    const c = clean_view(cfg);
    if (c.values != .array) return;
    if (@as(i64, @intCast(value.len)) < c.min) return;
    const forms = [_][]const u8{ value, clean_base64(value), h.esc_url(value), clean_json_escape(value) };
    var changed = false;
    for (forms) |form| {
        if (form.len == 0 or @as(i64, @intCast(form.len)) < c.min) continue;
        if (clean_values_has(c.values, form)) continue;
        c.values.array.append(h.vstr(form)) catch {};
        changed = true;
    }
    if (changed) std.mem.sort(Value, c.values.array.data.items, {}, clean_longer_first);
}

pub fn clean_add_util(ctx: *Context, value: []const u8) void {
    clean_add_cfg(clean_config(ctx), value);
}

fn clean_mask_value(c: CleanCfg, value: []const u8) []const u8 {
    if (0 < c.hint and @as(i64, @intCast(value.len)) > 2 * c.hint) {
        const keep: usize = @intCast(c.hint);
        return fmt("{s}{s}", .{ c.mask, value[value.len - keep ..] });
    }
    return c.mask;
}

fn clean_string(c: CleanCfg, text: []const u8) []const u8 {
    var out = text;
    if (c.values != .array) return out;
    for (c.values.array.data.items) |v| {
        if (v != .string or v.string.len == 0) continue;
        if (std.mem.indexOf(u8, out, v.string) != null) {
            out = std.mem.replaceOwned(u8, h.A(), out, v.string, clean_mask_value(c, v.string)) catch out;
        }
    }
    return out;
}

fn clean_sensitive_key(c: CleanCfg, key: ?[]const u8) bool {
    const k = key orelse return false;
    if (c.keys != .array) return false;
    const nk = clean_normkey(k);
    for (c.keys.array.data.items) |kv| {
        if (kv == .string and kv.string.len != 0 and std.mem.indexOf(u8, nk, kv.string) != null) return true;
    }
    return false;
}

fn clean_seen(seen: []const usize, id: usize) bool {
    for (seen) |s| {
        if (s == id) return true;
    }
    return false;
}

// A registered value used as a property name is masked like any other
// string; names that mask alike take a counter, so none is lost.
fn clean_name(c: CleanCfg, out: Value, key: []const u8) []const u8 {
    const name = clean_string(c, key);
    if (std.mem.eql(u8, name, key) or out.object.get(name) == null) return name;
    var i: usize = 1;
    while (out.object.get(fmt("{s}#{d}", .{ name, i })) != null) i += 1;
    return fmt("{s}#{d}", .{ name, i });
}

// A masked plain-data copy: functions dropped, cycles cut, and nothing
// shared with the live value, whose spec must stay raw.
fn clean_snapshot(c: CleanCfg, val: Value, key: ?[]const u8, depth: usize, seen: *std.ArrayList(usize)) Value {
    switch (val) {
        .null => return val,
        .string => |s| return h.vstr(if (clean_sensitive_key(c, key)) clean_mask_value(c, s) else clean_string(c, s)),
        .function => return h.vnull(),
        .bool, .integer, .float, .number_string => return if (clean_sensitive_key(c, key)) h.vstr(c.mask) else val,
        .object => |m| {
            const id = @intFromPtr(m);
            if (CLEAN_MAXDEPTH <= depth or clean_seen(seen.items, id)) return h.vstr(CLEAN_CIRCULAR);
            if (clean_sensitive_key(c, key)) return h.vstr(c.mask);
            seen.append(h.A(), id) catch {};
            defer _ = seen.pop();
            const out = h.omap();
            var it = m.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* == .function) continue;
                const v = clean_snapshot(c, kv.value_ptr.*, kv.key_ptr.*, depth + 1, seen);
                h.setp(out, clean_name(c, out, kv.key_ptr.*), v);
            }
            return out;
        },
        .array => |l| {
            const id = @intFromPtr(l);
            if (CLEAN_MAXDEPTH <= depth or clean_seen(seen.items, id)) return h.vstr(CLEAN_CIRCULAR);
            if (clean_sensitive_key(c, key)) return h.vstr(c.mask);
            seen.append(h.A(), id) catch {};
            defer _ = seen.pop();
            const out = h.olist();
            for (l.data.items) |item| {
                out.array.append(clean_snapshot(c, item, null, depth + 1, seen)) catch {};
            }
            return out;
        },
    }
}

pub fn clean_util(ctx: *Context, val: Value) Value {
    const c = clean_view(clean_config(ctx));
    if (!c.active) return val;
    var seen: std.ArrayList(usize) = .empty;
    return clean_snapshot(c, val, null, 0, &seen);
}

pub fn clean_str_util(ctx: *Context, val: []const u8) []const u8 {
    const c = clean_view(clean_config(ctx));
    if (!c.active) return val;
    return clean_string(c, val);
}

pub fn clean_key_util(ctx: *Context, key: []const u8) bool {
    return clean_sensitive_key(clean_view(clean_config(ctx)), key);
}

// Every scalar under a sensitive name, at any depth and of any shape, is
// registered: a credential mistyped as a map or a number is still a
// credential.
pub fn clean_add_sensitive_cfg(cfg: Value, val: Value) void {
    var seen: std.ArrayList(usize) = .empty;
    clean_add_sensitive_in(cfg, clean_view(cfg), val, false, 0, &seen);
}

pub fn clean_add_sensitive_util(ctx: *Context, val: Value) void {
    clean_add_sensitive_cfg(clean_config(ctx), val);
}

fn clean_add_sensitive_in(cfg: Value, c: CleanCfg, val: Value, under: bool, depth: usize, seen: *std.ArrayList(usize)) void {
    if (CLEAN_MAXDEPTH <= depth) return;
    switch (val) {
        .string, .integer, .float, .number_string => {
            if (under) clean_add_cfg(cfg, h.scalar_str(val));
        },
        .object => |m| {
            const id = @intFromPtr(m);
            if (clean_seen(seen.items, id)) return;
            seen.append(h.A(), id) catch {};
            var it = m.iterator();
            while (it.next()) |kv| {
                const sub = under or clean_sensitive_key(c, kv.key_ptr.*);
                clean_add_sensitive_in(cfg, c, kv.value_ptr.*, sub, depth + 1, seen);
            }
        },
        .array => |l| {
            const id = @intFromPtr(l);
            if (clean_seen(seen.items, id)) return;
            seen.append(h.A(), id) catch {};
            for (l.data.items) |item| clean_add_sensitive_in(cfg, c, item, under, depth + 1, seen);
        },
        else => {},
    }
}

pub fn done_util(ctx: *Context) E!Value {
    clean_explain_util(ctx);

    if (ctx.result) |res| {
        if (res.ok) return res.resdata;
    }

    return make_error_util(ctx);
}

// Clean the explain record in place. The caller holds this map, so the
// masked entries replace its own; with clean off the cleaned record is that
// map, already current.
pub fn clean_explain_util(ctx: *Context) void {
    const c = ctx.ctrl;
    if (!c.has_explain()) return;
    const explain = c.explain;
    const cleaned = clean_util(ctx, explain);
    if (cleaned == .object and cleaned.object != explain.object) {
        explain.object.data.clearRetainingCapacity();
        var it = cleaned.object.iterator();
        while (it.next()) |kv| h.setp(explain, kv.key_ptr.*, kv.value_ptr.*);
    }
    // explain.result is a to_value snapshot, never the live result.
    if (h.getp(explain, "result") == .object) {
        h.del_prop(h.to_map(h.getp(explain, "result")), h.vstr("err"));
    }
}

pub fn make_error_util(ctx: *Context) E!Value {
    const in_err = ctx.take_err();

    const op = ctx.op;
    var opname = op.name;
    if (opname.len == 0 or std.mem.eql(u8, opname, "_")) opname = "unknown operation";

    const result: *SdkResult = ctx.result orelse blk: {
        const r = SdkResult.make(h.omap());
        ctx.result = r;
        break :blk r;
    };
    result.ok = false;

    const the_err: *err.UnivecError = in_err orelse (result.err orelse ctx.make_error("unknown", "unknown error"));

    const errmsg = the_err.msg;
    const msg0 = fmt("UnivecSDK: {s}: {s}", .{ opname, errmsg });
    const msg = clean_str_util(ctx, msg0);

    result.err = null;

    const spec_val: Value = if (ctx.spec) |s| s.to_value() else h.vnull();

    clean_explain_util(ctx);

    const c = ctx.ctrl;
    if (c.has_explain()) {
        h.setp(c.explain, "err", h.jo(&.{.{ "message", h.vstr(msg) }}));
    }

    const sdk_err = err.UnivecError.make("", msg);
    // A hook's own error supplies the code as well as the message.
    sdk_err.code = clean_str_util(ctx, the_err.code);
    sdk_err.result = clean_util(ctx, result.to_value());
    sdk_err.spec = clean_util(ctx, spec_val);

    c.err = sdk_err;

    // Fire PreUnexpected so observability features (metrics, telemetry, audit,
    // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
    // rbac short-circuit). Fires after ctrl.err is set so hooks can read the
    // error; features guard against double-recording when PreDone already fired.
    feature_hook_util(ctx, "PreUnexpected");

    if (c.throw != null and c.throw.? == false) {
        return result.resdata;
    }

    return ctx.fail_err(sdk_err);
}

// ============================================================================
// feature add / hook / init
// ============================================================================

pub fn feature_add_util(ctx: *Context, f: Feature) void {
    const client = ctx.client orelse return;
    const fopts = f.add_options();
    if (fopts == .object) {
        const before = h.get_str(fopts, "__before__") orelse "";
        const after = h.get_str(fopts, "__after__") orelse "";
        const replace = h.get_str(fopts, "__replace__") orelse "";
        if (before.len != 0 or after.len != 0 or replace.len != 0) {
            const feats = &client.features;
            var i: usize = 0;
            while (i < feats.items.len) : (i += 1) {
                const nm = feats.items[i].name();
                if (before.len != 0 and std.mem.eql(u8, before, nm)) {
                    feats.insert(h.A(), i, f) catch {};
                    return;
                }
                if (after.len != 0 and std.mem.eql(u8, after, nm)) {
                    feats.insert(h.A(), i + 1, f) catch {};
                    return;
                }
                if (replace.len != 0 and std.mem.eql(u8, replace, nm)) {
                    feats.items[i] = f;
                    return;
                }
            }
        }
    }
    client.features.append(h.A(), f) catch {};
}

pub fn feature_hook_util(ctx: *Context, name: []const u8) void {
    const client = ctx.client orelse return;
    // Snapshot so a hook that mutates the feature set is safe to iterate.
    var snap: std.ArrayList(Feature) = .empty;
    for (client.features.items) |f| snap.append(h.A(), f) catch {};
    for (snap.items) |f| f.dispatch(name, ctx);
}

pub fn feature_init_util(ctx: *Context, f: Feature) void {
    const fname = f.name();
    var fopts = h.omap();
    const options = ctx.options;
    if (options == .object) {
        const feature_opts = h.to_map(h.getp(options, "feature"));
        if (feature_opts == .object) {
            const fo = h.to_map(h.getp(feature_opts, fname));
            if (fo == .object) fopts = fo;
        }
    }
    if (h.get_bool(fopts, "active") orelse false) {
        f.callInit(ctx, fopts);
    }
}

// ============================================================================
// make_options
// ============================================================================

fn mo_str_less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn mo_plain(val: Value, name: ?[]const u8) Value {
    if (val != .object) return val;
    const rbac = if (name) |n| std.mem.eql(u8, n, "rbac") else false;
    const out = h.omap();
    var it = val.object.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (std.mem.eql(u8, k, "entity") or (rbac and std.mem.eql(u8, k, "rules"))) continue;
        h.setp(out, k, kv.value_ptr.*);
    }
    return out;
}

// The options to scan for secrets. The feature map is keyed by feature
// names, not field names, so it is scanned as a list: `secrets` must not
// make every setting of that feature a secret. Entity blocks hold entity
// settings and seeded records, never a credential, so none is scanned, and
// nor are rbac's rules, keyed by entity and operation names. The raw scan
// still sees the feature list form, whose entries each carry `name`.
fn mo_without(opts: Value, keys: []const []const u8) Value {
    const out = h.omap();
    if (opts != .object) return out;
    var it = opts.object.iterator();
    outer: while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (std.mem.eql(u8, key, "entity")) continue;
        for (keys) |k| {
            if (std.mem.eql(u8, key, k)) continue :outer;
        }
        const v = kv.value_ptr.*;
        if (std.mem.eql(u8, key, "feature") and (v == .object or v == .array)) {
            const list = h.olist();
            if (v == .object) {
                var fit = v.object.iterator();
                while (fit.next()) |f| list.array.append(mo_plain(f.value_ptr.*, f.key_ptr.*)) catch {};
            } else {
                for (v.array.data.items) |f| list.array.append(mo_plain(f, h.get_str(f, "name"))) catch {};
            }
            h.setp(out, key, list);
        } else if (std.mem.eql(u8, key, "test")) {
            h.setp(out, key, mo_plain(v, null));
        } else {
            h.setp(out, key, v);
        }
    }
    return out;
}

pub fn make_options_util(ctx: *Context) Value {
    const options: Value = switch (ctx.options) {
        .object => ctx.options,
        else => h.omap(),
    };

    // Merge custom utility overrides onto the utility object (function values
    // are shared by reference — gotcha #8).
    const custom_utils = h.to_map(h.getp(options, "utility"));
    if (custom_utils == .object) {
        if (ctx.utility) |utility| {
            const custom = utility.custom;
            var it = custom_utils.object.iterator();
            while (it.next()) |kv| h.setp(custom, kv.key_ptr.*, kv.value_ptr.*);
        }
    }

    // `auth: null` is the documented way to suppress auth outright, and
    // prepare_auth honours it before it ever reads the apikey. It cannot
    // survive validate: a stored null reads as "no value", so the optspec
    // `auth` default fires and the suppression becomes "use the default auth"
    // - transmitting the credential the caller withheld. Withhold the key for
    // validate, then put the null back. Same fix as ts/js/go make_options.
    //
    // Value has no separate undefined variant (is_noval IS `== .null`), so
    // getp cannot tell an absent key from a stored null. The raw MapRef.get
    // optional can: a null OPTIONAL is absent, a `.null` payload is a stored
    // JSON null.
    const auth_suppressed = switch (options) {
        .object => |m| if (m.get("auth")) |a| a == .null else false,
        else => false,
    };

    var opts = h.clone(options);

    const config = ctx.config;
    const cfgopts: Value = switch (h.to_map(h.getp(config, "options"))) {
        .object => h.to_map(h.getp(config, "options")),
        else => h.omap(),
    };

    // The secret registry exists BEFORE validation, fed from the raw input, so
    // the constructor's own rejection of a mistyped credential is clean too.
    const cfgclean = h.to_map(h.getp(cfgopts, "clean"));
    const rawclean = h.to_map(h.getp(opts, "clean"));
    const cleancfg = make_clean_config(h.merge(h.ja(&.{
        h.omap(),
        h.clone(h.getp(schema.shared_optspec(), "clean")),
        if (cfgclean == .object) h.clone(cfgclean) else h.omap(),
        if (rawclean == .object) h.clone(rawclean) else h.omap(),
    })));
    clean_add_sensitive_cfg(cleancfg, mo_without(opts, &.{"clean"}));
    for (clean_splitvalues(h.getp(cfgclean, "values"))) |raw| clean_add_cfg(cleancfg, raw);
    for (clean_splitvalues(h.getp(rawclean, "values"))) |raw| clean_add_cfg(cleancfg, raw);

    if (auth_suppressed) h.del_prop(opts, h.vstr("auth"));

    // Feature add-order. options.feature may be an ordered list of
    // { name, active, ...opts } entries (the list position IS the order in
    // which features are added), or a { name: {opts} } map. Normalize a list
    // to a map (so merge/validate are unchanged) and remember the explicit
    // order; a map defaults to test-first so the `test` mock transport is
    // installed as the base of the transport wrapper chain.
    const feature_order = h.olist();
    const raw_feature = h.getp(opts, "feature");
    if (raw_feature == .array) {
        const fmap = h.omap();
        for (raw_feature.array.data.items) |entry| {
            if (entry == .object) {
                if (h.get_str(entry, "name")) |nm| {
                    const fopts = h.clone(entry);
                    h.del_prop(fopts, h.vstr("name"));
                    h.setp(fmap, nm, fopts);
                    feature_order.array.append(h.vstr(nm)) catch {};
                }
            }
        }
        h.setp(opts, "feature", fmap);
    }

    // THE OPTION SPEC IS GENERATED, NOT WRITTEN HERE.
    //
    // Built from the model: `main.kit.optspec` for the standard options, plus
    // one entry per feature this target carries, from that feature's own
    // `config.options` / `config.optspec`. Editing this file to add an option
    // would put it back where it was - one of twenty hand-maintained copies of
    // a schema nothing cross-checked - so add it to the model instead and
    // every ported target validates it.
    //
    // Parsed once and shared: make_options validates AGAINST the spec and
    // writes into the options, never into the spec.
    const optspec = schema.shared_optspec();

    // Preserve system.fetch before merge/validate (validation strips it).
    const sys_fetch = h.getpath(&.{ "system", "fetch" }, opts);

    // CLONE the config side: `config` is a process-wide singleton
    // (config.shared_config) and merge uses its nested maps as merge TARGETS,
    // so without this one client's options (headers, server, ...) are written
    // into the shared config and inherited by every client built after it.
    const merged = vs.merge(h.A(), h.ja(&.{ h.omap(), h.clone(cfgopts), opts }), vs.MAXDEPTH) catch opts;
    const vres = vs.validate(h.A(), merged, optspec) catch null;
    if (vres) |vr| {
        if (vr.err == null and vr.out == .object) opts = vr.out;
    }

    // Restore the suppression the optspec default would otherwise erase. setp
    // does a direct map put, so the explicit null is STORED, not treated as a
    // delete.
    if (auth_suppressed) h.setp(opts, "auth", h.vnull());

    // Resolve a templated base URL (e.g. https://{tenant_id}.hanko.io).
    // Every placeholder must resolve to a non-empty value: from options.server
    // (user), else the Config default. A placeholder that resolves to "" is a
    // construction ERROR in live mode - the URL cannot work - but in test mode
    // substitutes the deterministic value "test-<name>" so offline tests need
    // no configuration. The SDK constructor has no error return, so a missing
    // required variable PANICS: construction-time misconfiguration.
    //
    // Scanned by hand: a placeholder is `{` followed by [A-Za-z0-9_]+ and `}`;
    // anything else is literal text, so a stray brace in a URL is left alone.
    switch (h.getp(opts, "base")) {
        .string => |base| {
            if (null != std.mem.indexOfScalar(u8, base, '{')) {
                const testmode =
                    is_true(h.getpath(&.{ "test", "active" }, opts)) or
                    is_true(h.getpath(&.{ "feature", "test", "active" }, opts));
                const server = h.getp(opts, "server");
                const sdkname: []const u8 = switch (h.getpath(&.{ "main", "name" }, config)) {
                    .string => |s| if (0 < s.len) s else "SDK",
                    else => "SDK",
                };

                var out: std.ArrayList(u8) = .empty;
                var i: usize = 0;
                while (i < base.len) {
                    if ('{' != base[i]) {
                        out.append(h.A(), base[i]) catch {};
                        i += 1;
                        continue;
                    }
                    var j = i + 1;
                    while (j < base.len and (std.ascii.isAlphanumeric(base[j]) or '_' == base[j])) {
                        j += 1;
                    }
                    if (j >= base.len or '}' != base[j] or j == i + 1) {
                        out.append(h.A(), base[i]) catch {};
                        i += 1;
                        continue;
                    }
                    const name = base[i + 1 .. j];
                    const val: []const u8 = switch (h.getp(server, name)) {
                        .string => |s| s,
                        else => "",
                    };
                    if (0 == val.len) {
                        if (testmode) {
                            out.appendSlice(h.A(), "test-") catch {};
                            out.appendSlice(h.A(), name) catch {};
                        } else {
                            std.debug.panic(
                                "{s}: the server variable '{s}' is required: the API " ++
                                    "base URL is '{s}' - pass .server = .{{ .{s} = \"...\" }} " ++
                                    "in the SDK options",
                                .{ sdkname, name, base, name },
                            );
                        }
                    } else {
                        out.appendSlice(h.A(), val) catch {};
                    }
                    i = j + 1;
                }
                h.setp(opts, "base", h.vstr(out.toOwnedSlice(h.A()) catch base));
            }
        },
        else => {},
    }

    // Restore system.fetch.
    if (!h.is_noval(sys_fetch)) {
        const sysv = h.getp(opts, "system");
        if (sysv == .object) {
            h.setp(sysv, "fetch", sys_fetch);
        } else {
            h.setp(opts, "system", h.jo(&.{.{ "fetch", sys_fetch }}));
        }
    }

    // Resolve the feature add-order: an explicit list order (above) wins;
    // otherwise order the map test-first, then the remaining names sorted, so
    // the outcome is deterministic and `test` is always the base transport.
    if (feature_order.array.data.items.len == 0) {
        const fmapv = h.getp(opts, "feature");
        if (fmapv == .object) {
            var names: std.ArrayList([]const u8) = .empty;
            var nit = fmapv.object.iterator();
            while (nit.next()) |kv| names.append(h.A(), kv.key_ptr.*) catch {};
            std.mem.sort([]const u8, names.items, {}, mo_str_less);
            var has_test = false;
            for (names.items) |nm| {
                if (std.mem.eql(u8, nm, "test")) has_test = true;
            }
            if (has_test) feature_order.array.append(h.vstr("test")) catch {};
            for (names.items) |nm| {
                if (!std.mem.eql(u8, nm, "test")) feature_order.array.append(h.vstr(nm)) catch {};
            }
        }
    }

    h.setp(opts, "__derived__", h.jo(&.{
        .{ "clean", cleancfg },
        .{ "featureorder", feature_order },
    }));

    // Again over the merged result: the config's own defaults can carry one.
    clean_add_sensitive_cfg(cleancfg, mo_without(opts, &.{ "clean", "__derived__" }));

    return opts;
}

// ============================================================================
// make_point (gotcha #2: rbac PrePoint short-circuit)
// ============================================================================

// How many path segments a point has.
fn point_parts_len(point: Value) i64 {
    const parts = h.getp(point, "parts");
    if (parts != .array) return 0;
    return @intCast(parts.array.data.items.len);
}

// Does this point's path end in a parameter? A record route ends in the
// record's identifier (/boards/{id}); a cross-reference that also returns the
// entity ends in the relationship's name (/posts/{id}/author). That, then
// fewest segments, is what tells the entity's own route from a
// cross-reference. The same rule runs at generation time, in
// helpers/opShape.ts — both sides must move together.
fn point_terminal_param(point: Value) bool {
    const parts = h.getp(point, "parts");
    if (parts != .array) return false;
    const items = parts.array.data.items;
    if (0 == items.len) return false;
    const last = items[items.len - 1];
    if (last != .string) return false;
    return 0 < last.string.len and '{' == last.string[0];
}

fn own_point(points: []const Value) Value {
    var best = points[0];
    for (points) |cand| {
        const cand_term = point_terminal_param(cand);
        const best_term = point_terminal_param(best);
        if (cand_term != best_term) {
            if (cand_term) best = cand;
        } else if (point_parts_len(cand) < point_parts_len(best)) {
            best = cand;
        }
    }
    return best;
}

// The path parameters of a point that neither the call nor the entity gives a
// value for, looked up as param_util looks them up.
fn unfilled_params(ctx: *Context, point: Value) [][]const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    const parts = h.getp(point, "parts");
    if (parts == .array) {
        for (parts.array.data.items) |part| {
            if (part != .string) continue;
            const text = part.string;
            if (text.len < 3 or '{' != text[0] or '}' != text[text.len - 1] or
                std.mem.indexOfAny(u8, text[1 .. text.len - 1], "{}/") != null) continue;
            const name = text[1 .. text.len - 1];
            if (h.is_noval(param_value(ctx, point, name))) missing.append(h.A(), name) catch {};
        }
    }
    return missing.toOwnedSlice(h.A()) catch &.{};
}

pub fn make_point_util(ctx: *Context) E!Value {
    if (ctx.out_get("point")) |ov| {
        switch (ov) {
            .err => |e| return ctx.fail_err(e),
            .val => |v| {
                if (v == .object) {
                    ctx.point = v;
                    return v;
                }
            },
            else => {},
        }
    }

    const op = ctx.op;
    const options = ctx.options;

    const allow_op: []const u8 = switch (h.getpath(&.{ "allow", "op" }, options)) {
        .string => |s| s,
        else => "",
    };
    if (!h.allow_list_has(h.getpath(&.{ "allow", "op" }, options), op.name)) {
        return ctx.fail("point_op_allow", fmt("Operation \"{s}\" not allowed by SDK option allow.op value: \"{s}\"", .{ op.name, allow_op }));
    }

    const points = op.points;
    const plen = h.sizeOf(points);

    if (plen == 0) {
        return ctx.fail("point_no_points", fmt("Operation \"{s}\" has no endpoint definitions.", .{op.name}));
    }

    if (plen == 1) {
        ctx.point = h.get_elem(points, h.vnum(0), h.vnull());
    } else {
        const reqselector: Value = if (std.mem.eql(u8, op.input, "data")) ctx.reqdata else ctx.reqmatch;
        const selector: Value = if (std.mem.eql(u8, op.input, "data")) ctx.data else ctx.mtch;

        var point: Value = h.vnull();
        var matched = false;
        var i: i64 = 0;
        while (i < plen) : (i += 1) {
            const cand = h.get_elem(points, h.vnum(i), h.vnull());
            const select_def = h.to_map(h.getp(cand, "select"));
            var found = true;

            if (!h.is_noval(selector) and !h.is_noval(select_def)) {
                const exist = h.getp(select_def, "exist");
                if (exist == .array) {
                    for (exist.array.data.items) |ek| {
                        if (ek == .string) {
                            const existkey = ek.string;
                            const rv = h.getp(reqselector, existkey);
                            const sv = h.getp(selector, existkey);
                            if (h.is_noval(rv) and h.is_noval(sv)) {
                                found = false;
                                break;
                            }
                        }
                    }
                }
            }

            if (found) {
                const req_action = h.getp(reqselector, "$action");
                const select_action = h.getp(select_def, "$action");
                if (!h.veq(req_action, select_action)) found = false;
            }

            if (found) {
                point = cand;
                matched = true;
                break;
            }
        }

        // select.exist can list more than the params needed to pick a point
        // (for /boards/{id} it is Trello's 17 optional query-includes), so a
        // plain {id} call matches NOTHING. Fall back to the entity's own
        // route rather than whichever point came last.
        if (!matched) {
            // A request naming an action reaches here only because that
            // action's own point failed its exist test, so it is unbuildable
            // whatever we pick. Refuse it BEFORE choosing a fallback: the
            // guard below compares the chosen point's $action and would wave
            // the request through whenever the fallback lands on the action
            // point itself.
            const unmatched_action = h.getp(reqselector, "$action");
            if (!h.is_noval(unmatched_action)) {
                return ctx.fail("point_action_invalid", fmt("Operation \"{s}\" action \"{s}\" is not valid.", .{ op.name, h.stringify(unmatched_action) }));
            }

            // A call without an action falls back to a point without one, as
            // generation does, and only to a route the call can fill.
            var plain: std.ArrayList(Value) = .empty;
            var j: i64 = 0;
            while (j < plen) : (j += 1) {
                const cand = h.get_elem(points, h.vnum(j), h.vnull());
                if (h.is_noval(h.getp(h.to_map(h.getp(cand, "select")), "$action"))) plain.append(h.A(), cand) catch {};
            }
            if (0 == plain.items.len) {
                return ctx.fail("point_action_required", fmt("Operation \"{s}\" has only action endpoints; pass $action to choose one.", .{op.name}));
            }
            var fillable: std.ArrayList(Value) = .empty;
            for (plain.items) |cand| {
                if (0 == unfilled_params(ctx, cand).len) fillable.append(h.A(), cand) catch {};
            }

            if (0 == fillable.items.len) {
                const missing = std.mem.join(h.A(), ", ", unfilled_params(ctx, own_point(plain.items))) catch "";
                return ctx.fail("point_no_match", fmt("Operation \"{s}\" has no endpoint whose path parameters are all given (missing: {s}).", .{ op.name, missing }));
            }

            point = own_point(fillable.items);
        }

        const req_action = h.getp(reqselector, "$action");
        if (!h.is_noval(req_action) and !h.is_noval(point)) {
            const point_select = h.to_map(h.getp(point, "select"));
            const point_action = h.getp(point_select, "$action");
            if (!h.veq(req_action, point_action)) {
                return ctx.fail("point_action_invalid", fmt("Operation \"{s}\" action \"{s}\" is not valid.", .{ op.name, h.stringify(req_action) }));
            }
        }

        ctx.point = point;
    }

    return ctx.point;
}

// ============================================================================
// make_spec / make_url / make_fetch_def
// ============================================================================

pub fn make_spec_util(ctx: *Context) E!*Spec {
    if (ctx.out_get("spec")) |ov| {
        switch (ov) {
            // A PreSpec feature hook (e.g. validate) may short-circuit the
            // operation by storing an error here; surface it before the
            // request is built, the same way make_point surfaces
            // out["point"].
            .err => |e| return ctx.fail_err(e),
            .spec => |sp| {
                ctx.spec = sp;
                return sp;
            },
            else => {},
        }
    }

    const point = ctx.point;
    const options = ctx.options;

    const specmap = h.omap();
    h.setp(specmap, "base", h.getp(options, "base"));
    h.setp(specmap, "prefix", h.getp(options, "prefix"));
    h.setp(specmap, "suffix", h.getp(options, "suffix"));
    h.setp(specmap, "parts", h.getp(point, "parts"));
    h.setp(specmap, "step", h.vstr("start"));

    const spec = Spec.make(specmap);
    ctx.spec = spec;

    const method = prepare_method_util(ctx);
    spec.method = method;

    const allow_method: []const u8 = switch (h.getpath(&.{ "allow", "method" }, options)) {
        .string => |s| s,
        else => "",
    };
    if (!h.allow_list_has(h.getpath(&.{ "allow", "method" }, options), method)) {
        return ctx.fail("spec_method_allow", fmt("Method \"{s}\" not allowed by SDK option allow.method value: \"{s}\"", .{ method, allow_method }));
    }

    spec.params = prepare_params_util(ctx);
    spec.query = prepare_query_util(ctx);
    spec.headers = prepare_headers_util(ctx);

    const kind: []const u8 = switch (h.getp(point, "kind")) {
        .string => |s| s,
        else => "",
    };

    if (std.mem.eql(u8, kind, "graphql")) {
        // GraphQL addresses one endpoint: no path parts, no query string,
        // and the body carries the operation. prepare_body is skipped
        // deliberately — it only emits a body for data-input ops, whereas
        // every GraphQL op posts one, including load/list/remove.
        spec.body = graphql_body_util(ctx);
        spec.path = "";
        // prepare_query already copied the op's match arguments into the
        // query string. Those same values are bound as operation variables,
        // so leaving them would send /graphql?id=i1.
        spec.query = h.omap();
        h.setp(spec.headers, "content-type", h.vstr(GRAPHQL_CONTENT_TYPE));
    } else {
        spec.body = prepare_body_util(ctx);
        spec.path = prepare_path_util(ctx);
    }

    const c = ctx.ctrl;
    if (c.has_explain()) h.setp(c.explain, "spec", spec.to_value());

    const query = h.clone(spec.query);
    const spec2 = try prepare_auth_util(ctx);
    spec2.note_authquery(query);
    ctx.spec = spec2;
    return spec2;
}

// The {name} placeholders in a text, in order.
fn placeholders(text: []const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if ('{' != text[i]) continue;
        const rest = text[i + 1 ..];
        const n = std.mem.indexOfAny(u8, rest, "{}/") orelse rest.len;
        if (0 < n and n < rest.len and '}' == rest[n]) {
            out.append(h.A(), text[i .. i + n + 2]) catch {};
            i += n + 1;
        }
    }
    return out.toOwnedSlice(h.A()) catch &.{};
}

pub fn make_url_util(ctx: *Context) E![]const u8 {
    const spec = ctx.spec orelse return ctx.fail("url_no_spec", "Expected context spec property to be defined.");
    const result = ctx.result orelse return ctx.fail("url_no_result", "Expected context result property to be defined.");

    var url = vs.join(h.A(), h.ja(&.{
        h.vstr(spec.base),
        h.vstr(spec.prefix),
        h.vstr(spec.path),
        h.vstr(spec.suffix),
    }), "/", true) catch "";

    // A route the definition ends with a slash keeps it: a server such as a
    // Django REST one redirects or refuses the route without it.
    const orig = h.getp(ctx.point, "orig");
    if (orig == .string and std.mem.endsWith(u8, orig.string, "/") and spec.suffix.len == 0 and
        !std.mem.endsWith(u8, url, "/"))
    {
        url = std.mem.concat(h.A(), u8, &.{ url, "/" }) catch url;
    }

    const resmatch = h.omap();

    if (spec.params == .object) {
        var it = spec.params.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            if (!h.is_noval(val)) {
                const needle = fmt("{{{s}}}", .{key});
                const sub = h.esc_url(h.scalar_str(val));
                url = std.mem.replaceOwned(u8, h.A(), url, needle, sub) catch url;
                h.setp(resmatch, key, val);
            }
        }
    }

    // A placeholder left in the route would send the request to the wrong route.
    // The base's own placeholders are server variables, resolved with the options.
    var blen = spec.base.len;
    while (0 < blen and '/' == spec.base[blen - 1]) blen -= 1;
    const route = if (std.mem.startsWith(u8, url, spec.base[0..blen])) url[blen..] else url;
    const unfilled = placeholders(route);
    if (0 < unfilled.len) {
        return ctx.fail("url_param_missing", fmt("URL path has no value for {s}.", .{std.mem.join(h.A(), ", ", unfilled) catch ""}));
    }

    var qsep: []const u8 = "?";
    if (spec.query == .object) {
        var it = spec.query.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            if (!h.is_noval(val)) {
                url = fmt("{s}{s}{s}={s}", .{ url, qsep, h.esc_url(key), h.esc_url(h.scalar_str(val)) });
                qsep = "&";
                // Sent with the request, never recorded as the entity's match.
                if (!spec.authquery_has(key)) h.setp(resmatch, key, val);
            }
        }
    }

    result.resmatch = resmatch;
    return url;
}

pub fn make_fetch_def_util(ctx: *Context) E!Value {
    const spec = ctx.spec orelse return ctx.fail("fetchdef_no_spec", "Expected context spec property to be defined.");

    if (ctx.result == null) ctx.result = SdkResult.make(h.omap());

    spec.step = "prepare";

    const url = try make_url_util(ctx);
    spec.url = url;

    const fetchdef = h.omap();
    h.setp(fetchdef, "url", h.vstr(url));
    h.setp(fetchdef, "method", h.vstr(spec.method));
    h.setp(fetchdef, "headers", spec.headers);

    // A map or a list is JSON, and so is a scalar on a point that declares a
    // JSON body. Anything else goes as given.
    const body = spec.body;
    if (!h.is_noval(body)) {
        const encode = switch (body) {
            .object, .array => true,
            .string, .integer, .float, .number_string, .bool => is_json_request(ctx.point),
            else => false,
        };
        if (encode) {
            h.setp(fetchdef, "body", h.vstr(h.jsonify_compact(body)));
        } else {
            h.setp(fetchdef, "body", body);
        }
    }

    return fetchdef;
}

// ============================================================================
// make_request / make_response / make_result
// ============================================================================

pub fn make_request_util(ctx: *Context) E!*Response {
    if (ctx.out_get("request")) |ov| {
        switch (ov) {
            .response => |resp| return resp,
            else => {},
        }
    }

    const response = Response.make(h.omap());
    ctx.result = SdkResult.make(h.omap());

    const spec = ctx.spec orelse return ctx.fail("request_no_spec", "Expected context spec property to be defined.");

    const fetchdef = make_fetch_def_util(ctx) catch {
        response.err = ctx.take_err();
        ctx.response = response;
        spec.step = "postrequest";
        return response;
    };

    const c = ctx.ctrl;
    if (c.has_explain()) h.setp(c.explain, "fetchdef", fetchdef);

    spec.step = "prerequest";

    const url = h.get_str(fetchdef, "url") orelse "";
    const fetched = ctx.util().fetch(ctx, url, fetchdef);

    var out_resp: *Response = response;
    if (fetched) |fv| {
        switch (fv) {
            .object => out_resp = Response.make(fv),
            .null => {
                const r = Response.make(h.omap());
                r.err = ctx.make_error("request_no_response", "response: undefined");
                out_resp = r;
            },
            else => {
                response.err = ctx.make_error("request_invalid_response", "response: invalid type");
                out_resp = response;
            },
        }
    } else |_| {
        response.err = ctx.take_err();
        out_resp = response;
    }

    spec.step = "postrequest";
    ctx.response = out_resp;
    return out_resp;
}

pub fn make_response_util(ctx: *Context) E!*Response {
    if (ctx.out_get("response")) |ov| {
        switch (ov) {
            .response => |resp| return resp,
            else => {},
        }
    }

    const spec = ctx.spec orelse return ctx.fail("response_no_spec", "Expected context spec property to be defined.");
    const response = ctx.response orelse return ctx.fail("response_no_response", "Expected context response property to be defined.");
    const result = ctx.result orelse return ctx.fail("response_no_result", "Expected context result property to be defined.");

    spec.step = "response";

    _ = result_basic_util(ctx);
    _ = result_headers_util(ctx);
    _ = result_body_util(ctx);

    // GraphQL reports failures as a top-level `errors` array under HTTP 200,
    // so result_basic's status check never sees them. Lift them here, before
    // the response transform tries to unwrap data that is not there.
    _ = graphql_errors_util(ctx);

    _ = transform_response_util(ctx);

    if (result.err == null) result.ok = true;

    const c = ctx.ctrl;
    if (c.has_explain()) h.setp(c.explain, "result", result.to_value());

    return response;
}

pub fn make_result_util(ctx: *Context) E!*SdkResult {
    if (ctx.out_get("result")) |ov| {
        switch (ov) {
            .result => |res| return res,
            else => {},
        }
    }

    const op = ctx.op;
    const entity = ctx.entity;
    const spec = ctx.spec orelse return ctx.fail("result_no_spec", "Expected context spec property to be defined.");
    const result = ctx.result orelse return ctx.fail("result_no_result", "Expected context result property to be defined.");

    spec.step = "result";

    _ = transform_response_util(ctx);

    if (std.mem.eql(u8, op.name, "list")) {
        const resdata = result.resdata;
        result.resdata = h.olist();

        if (resdata == .array and entity != null) {
            const ent = entity.?;
            if (resdata.array.data.items.len != 0) {
                const entities = h.olist();
                for (resdata.array.data.items) |entry| {
                    const e = ent.makeEnt();
                    const out = if (entry == .object) e.data(entry) else e.data(null);
                    entities.array.append(out) catch {};
                }
                result.resdata = entities;
            }
        }
    }

    const c = ctx.ctrl;
    if (c.has_explain()) h.setp(c.explain, "result", result.to_value());

    return result;
}

// ============================================================================
// param / prepare_* / result_* / transform_*
// ============================================================================

pub fn param_util(ctx: *Context, paramdef: Value) Value {
    const pt = h.typify(paramdef);

    const key: []const u8 = if (0 != ((@as(i64, vs.T_string)) & pt))
        (switch (paramdef) {
            .string => |s| s,
            else => "",
        })
    else
        (h.get_str(paramdef, "name") orelse "");

    const akey = param_alias(ctx.point, key);
    if (akey.len != 0 and h.is_noval(h.getp(ctx.reqmatch, key)) and h.is_noval(h.getp(ctx.mtch, key))) {
        if (ctx.spec) |sp| {
            h.setp(sp.alias, akey, h.vstr(key));
        }
    }

    return param_value(ctx, ctx.point, key);
}

// The name a point gives a parameter in the call, if it renames it.
fn param_alias(point: Value, key: []const u8) []const u8 {
    if (h.is_noval(point)) return "";
    const alias = h.to_map(h.getp(point, "alias"));
    if (h.is_noval(alias)) return "";
    return h.get_str(alias, key) orelse "";
}

// The value the call or its entity gives a point's parameter, under its name
// or the point's alias for it.
pub fn param_value(ctx: *Context, point: Value, key: []const u8) Value {
    const akey = param_alias(point, key);

    var val = h.getp(ctx.reqmatch, key);
    if (h.is_noval(val)) val = h.getp(ctx.mtch, key);
    if (h.is_noval(val) and akey.len != 0) val = h.getp(ctx.reqmatch, akey);
    if (h.is_noval(val)) val = h.getp(ctx.reqdata, key);
    if (h.is_noval(val)) val = h.getp(ctx.data, key);

    if (h.is_noval(val) and akey.len != 0) {
        val = h.getp(ctx.reqdata, akey);
        if (h.is_noval(val)) val = h.getp(ctx.data, akey);
    }

    return val;
}

pub fn prepare_method_util(ctx: *Context) []const u8 {
    const opname = ctx.op.name;

    // The API definition is authoritative: a POST-only or PATCH-based API
    // exposes `update` as POST or PATCH, not the PUT the op name implies.
    // Only fall back to the op-name convention when the point has no method.
    switch (h.getp(ctx.point, "method")) {
        .string => |m| {
            if (0 < m.len) {
                const upper = h.A().alloc(u8, m.len) catch return m;
                for (m, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
                return upper;
            }
        },
        else => {},
    }

    if (std.mem.eql(u8, opname, "create")) return "POST";
    if (std.mem.eql(u8, opname, "update")) return "PUT";
    if (std.mem.eql(u8, opname, "load")) return "GET";
    if (std.mem.eql(u8, opname, "list")) return "GET";
    if (std.mem.eql(u8, opname, "remove")) return "DELETE";
    if (std.mem.eql(u8, opname, "patch")) return "PATCH";

    // NO CATCH-ALL GET. The ts reference returns methodMap[key], which is
    // undefined for an op the map does not name, so the request is refused
    // rather than issued. Returning "GET" here made every unrecognised op a
    // GET — a mistyped or unsupported op quietly fetched — and the method
    // feeds the allow.method gate, so it is not cosmetic. ocaml had the same
    // fallback; the shared corpus caught both.
    return "";
}

// One argument a point declares, with the name it travels under and the value
// the call passes for it.
const CallArg = struct { name: []const u8, wire: []const u8, val: Value };

// The arguments a point declares in one location, query or header, each with
// the name it travels under and the value this call passes in its match or
// else its data. Unlike a path parameter, the entity's stored match and data
// never supply one.
fn call_args(ctx: *Context, kind: []const u8) []CallArg {
    var out: std.ArrayList(CallArg) = .empty;
    const defs: Value = h.getpath(&.{ "args", kind }, ctx.point);
    if (defs == .array) {
        for (defs.array.data.items) |ad| {
            const name = h.getp(ad, "name");
            if (name != .string or name.string.len == 0) continue;
            const orig = h.getp(ad, "orig");
            const wire: []const u8 = if (orig == .string and orig.string.len != 0) orig.string else name.string;
            var val = h.getp(ctx.reqmatch, name.string);
            if (h.is_noval(val)) val = h.getp(ctx.reqdata, name.string);
            out.append(h.A(), .{ .name = name.string, .wire = wire, .val = val }) catch {};
        }
    }
    return out.toOwnedSlice(h.A()) catch &.{};
}

// ============================================================================
// media
// ============================================================================

// The media types a point declares: `response` (the model's `rs`) for the
// Accept header, and `body` (the model's `rb`) for the request body.

// The data key holding a raw request body. Like `$action`, it can never be a
// declared argument name.
pub const RAW_BODY = "$body";

pub fn is_json_media(media: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, media, ';') orelse media.len;
    const m = std.mem.trim(u8, media[0..semi], " \t");
    return std.ascii.eqlIgnoreCase(m, "application/json") or
        std.ascii.eqlIgnoreCase(m, "text/json") or
        (m.len >= 5 and std.ascii.eqlIgnoreCase(m[m.len - 5 ..], "+json"));
}

fn media_text(v: Value) ?[]const u8 {
    return if (v == .string and v.string.len != 0) v.string else null;
}

// The declared JSON type alone, else every declared type in the model's
// order; null when no success response declares a body.
pub fn accept_of(point: Value) ?[]const u8 {
    const res = h.getp(point, "response");
    const media = media_text(h.getp(res, "media")) orelse return null;
    if (media_text(h.getp(res, "kind"))) |kind| {
        if (std.mem.eql(u8, kind, "json")) return media;
    }
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(h.A(), media) catch return media;
    const alts = h.getp(res, "alternatives");
    if (alts == .array) {
        for (alts.array.data.items) |alt| {
            const m = media_text(h.getp(alt, "media")) orelse continue;
            out.appendSlice(h.A(), ", ") catch return media;
            out.appendSlice(h.A(), m) catch return media;
        }
    }
    return out.toOwnedSlice(h.A()) catch media;
}

pub fn is_raw_request(point: Value) bool {
    const kind = media_text(h.getp(h.getp(point, "body"), "kind")) orelse return false;
    return std.mem.eql(u8, kind, "raw");
}

pub fn is_json_request(point: Value) bool {
    const kind = media_text(h.getp(h.getp(point, "body"), "kind")) orelse return false;
    return std.mem.eql(u8, kind, "json");
}

fn has_media_header(headers: Value, name: []const u8) bool {
    var kit = headers.object.iterator();
    while (kit.next()) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) return true;
    }
    return false;
}

// A caller's accept wins. A declared request type replaces each JSON
// content-type, the SDK default, and leaves any other the caller set.
pub fn media_headers(point: Value, headers: Value) void {
    if (headers != .object) return;
    if (accept_of(point)) |accept| {
        if (!has_media_header(headers, "accept")) h.setp(headers, "accept", h.vstr(accept));
    }

    const body = h.getp(point, "body");
    const kind = media_text(h.getp(body, "kind")) orelse return;
    const media = media_text(h.getp(body, "media")) orelse return;
    if (!std.mem.eql(u8, kind, "raw") and !std.mem.eql(u8, kind, "json")) return;
    while (true) {
        var kit = headers.object.iterator();
        const json: ?[]const u8 = while (kit.next()) |kv| {
            const v = kv.value_ptr.*;
            if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "content-type") and
                v == .string and is_json_media(v.string)) break kv.key_ptr.*;
        } else null;
        _ = headers.object.fetchOrderedRemove(json orelse break);
    }
    if (!has_media_header(headers, "content-type")) h.setp(headers, "content-type", h.vstr(media));
}

// A string of text or bytes, sent as it is.
pub fn raw_body(reqdata: Value) Value {
    return h.getp(reqdata, RAW_BODY);
}

pub fn prepare_headers_util(ctx: *Context) Value {
    const options: Value = if (ctx.client) |client| client.options_map() else ctx.options;

    const headers = h.getp(options, "headers");
    const out: Value = if (h.is_noval(headers)) h.omap() else switch (h.clone(headers)) {
        .object => h.clone(headers),
        else => h.omap(),
    };
    media_headers(ctx.point, out);

    // A header argument replaces a default of the same name, whatever its case.
    for (call_args(ctx, "header")) |arg| {
        if (h.is_noval(arg.val)) continue;
        const key = std.ascii.allocLowerString(h.A(), arg.wire) catch arg.wire;
        while (true) {
            var kit = out.object.iterator();
            const same: ?[]const u8 = while (kit.next()) |kv| {
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, key)) break kv.key_ptr.*;
            } else null;
            _ = out.object.fetchOrderedRemove(same orelse break);
        }
        h.setp(out, key, h.vstr(h.stringify(arg.val)));
    }

    // A cookie argument travels in the cookie header, form serialized and
    // percent-encoded, replacing a cookie of the same name among those the
    // caller's headers already send.
    var sent: std.ArrayList(CallArg) = .empty;
    for (call_args(ctx, "cookie")) |arg| {
        if (!h.is_noval(arg.val)) sent.append(h.A(), arg) catch {};
    }
    if (0 < sent.items.len) {
        var names: std.ArrayList([]const u8) = .empty;
        for (sent.items) |arg| {
            if (arg.val == .object) {
                for (h.keysof_vec(arg.val)) |key| names.append(h.A(), h.esc_url(key)) catch {};
            } else {
                names.append(h.A(), arg.wire) catch {};
            }
        }
        var kept: std.ArrayList([]const u8) = .empty;
        while (true) {
            var kit = out.object.iterator();
            const same: ?[]const u8 = while (kit.next()) |kv| {
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "cookie")) break kv.key_ptr.*;
            } else null;
            const removed = out.object.fetchOrderedRemove(same orelse break) orelse break;
            if (removed.value != .string) continue;
            for (h.cookie_keep(removed.value.string, names.items)) |cookie| kept.append(h.A(), cookie) catch {};
        }
        for (sent.items) |arg| {
            const pair = cookie_pair(arg.wire, arg.val);
            if (0 < pair.len) kept.append(h.A(), pair) catch {};
        }
        if (0 < kept.items.len) {
            const joined = std.mem.join(h.A(), "; ", kept.items) catch "";
            h.setp(out, "cookie", h.vstr(joined));
        }
    }

    return out;
}

fn keyLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// The form style of a cookie parameter: a list repeats the name, a map sends
// its own keys, and every value is percent-encoded.
fn cookie_pair(wire: []const u8, val: Value) []const u8 {
    var pairs: std.ArrayList([]const u8) = .empty;
    switch (val) {
        .array => |items| {
            for (items.data.items) |item| {
                const text = h.esc_url(h.stringify(item));
                const pair = std.fmt.allocPrint(h.A(), "{s}={s}", .{ wire, text }) catch continue;
                pairs.append(h.A(), pair) catch {};
            }
        },
        .object => {
            const keys = h.keysof_vec(val);
            std.mem.sort([]const u8, keys, {}, keyLessThan);
            for (keys) |key| {
                const text = h.esc_url(h.stringify(h.getp(val, key)));
                const pair = std.fmt.allocPrint(h.A(), "{s}={s}", .{ h.esc_url(key), text }) catch continue;
                pairs.append(h.A(), pair) catch {};
            }
        },
        else => {
            const text = h.esc_url(h.stringify(val));
            const pair = std.fmt.allocPrint(h.A(), "{s}={s}", .{ wire, text }) catch return "";
            pairs.append(h.A(), pair) catch {};
        },
    }
    return std.mem.join(h.A(), "; ", pairs.items) catch "";
}

pub fn prepare_body_util(ctx: *Context) Value {
    if (std.mem.eql(u8, ctx.op.input, "data")) {
        if (is_raw_request(ctx.point)) return raw_body(ctx.reqdata);
        return transform_request_util(ctx);
    }
    return h.vnull();
}

pub fn prepare_params_util(ctx: *Context) Value {
    const point = ctx.point;
    const args = h.to_map(h.getp(point, "args"));
    const params: Value = if (args == .object)
        (switch (h.getp(args, "params")) {
            .array => h.getp(args, "params"),
            else => h.olist(),
        })
    else
        h.olist();

    const out = h.omap();
    if (params == .array) {
        for (params.array.data.items) |pd| {
            const val = param_util(ctx, pd);
            if (!h.is_noval(val)) {
                if (pd == .object) {
                    if (h.get_str(pd, "name")) |name| {
                        if (name.len != 0) h.setp(out, name, val);
                    }
                }
            }
        }
    }
    return out;
}

pub fn prepare_path_util(ctx: *Context) []const u8 {
    const point = ctx.point;
    const parts: Value = switch (h.getp(point, "parts")) {
        .array => h.getp(point, "parts"),
        else => h.olist(),
    };
    return vs.join(h.A(), parts, "/", true) catch "";
}

// Whether a list of argument definitions names this key.
fn names_key(defs: Value, key: []const u8) bool {
    if (defs != .array) return false;
    for (defs.array.data.items) |d| {
        const name = h.getp(d, "name");
        if (name == .string and std.mem.eql(u8, name.string, key)) return true;
    }
    return false;
}

pub fn prepare_query_util(ctx: *Context) Value {
    const point = ctx.point;
    const reqmatch: Value = switch (ctx.reqmatch) {
        .object => ctx.reqmatch,
        else => h.omap(),
    };
    const params: Value = switch (h.getp(point, "params")) {
        .array => h.getp(point, "params"),
        else => h.olist(),
    };
    // A path parameter travels in the path. The generated config lists them
    // as args.params, which prepare_params reads; params is the older list.
    const aparams: Value = h.getpath(&.{ "args", "params" }, point);
    // A header or cookie parameter travels in the headers, which prepare_headers
    // fills, unless a query parameter shares its name: then both are sent.
    const aheader: Value = h.getpath(&.{ "args", "header" }, point);
    const acookie: Value = h.getpath(&.{ "args", "cookie" }, point);
    // A query parameter travels under the name the definition gives it, its
    // orig, which the model may have renamed for the caller.
    const aquery: Value = h.getpath(&.{ "args", "query" }, point);

    const out = h.omap();
    if (reqmatch == .object) {
        var it = reqmatch.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            var contained = false;
            if (params == .array) {
                for (params.array.data.items) |v| {
                    if (v == .string and std.mem.eql(u8, v.string, key)) {
                        contained = true;
                        break;
                    }
                }
            }
            if (!contained) contained = names_key(aparams, key) or
                ((names_key(aheader, key) or names_key(acookie, key)) and !names_key(aquery, key));
            var wire: []const u8 = key;
            if (aquery == .array) {
                for (aquery.array.data.items) |qd| {
                    const name = h.getp(qd, "name");
                    const orig = h.getp(qd, "orig");
                    if (name == .string and orig == .string and orig.string.len != 0 and
                        std.mem.eql(u8, name.string, key))
                    {
                        wire = orig.string;
                        break;
                    }
                }
            }
            if (!h.is_noval(val) and !std.mem.eql(u8, key, "$action") and !contained) h.setp(out, wire, val);
        }
    }

    // A create or update passes its query arguments in its data.
    for (call_args(ctx, "query")) |arg| {
        var contained = h.is_noval(arg.val) or names_key(aparams, arg.name) or
            ((names_key(aheader, arg.name) or names_key(acookie, arg.name)) and !names_key(aquery, arg.name));
        if (params == .array) {
            for (params.array.data.items) |v| {
                if (v == .string and std.mem.eql(u8, v.string, arg.name)) contained = true;
            }
        }
        if (!contained) h.setp(out, arg.wire, arg.val);
    }
    return out;
}

// ============================================================================
// graphql (transport)
//
// GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
// produces uses this code unchanged. The API-specific part — which
// operations exist and what each one's document is — is model data,
// computed once by apidef and emitted into Config.
//
// Two jobs:
//
//   graphql_body   — build { query, variables } for a point, binding the
//                    op's arguments to the document's declared variables.
//
//   graphql_errors — lift a GraphQL failure into an SDK error. GraphQL
//                    reports failures as a top-level `errors` array under
//                    HTTP 200, so the status-driven path in result_basic
//                    never sees them.
// ============================================================================

// Content type every GraphQL-over-HTTP request uses.
pub const GRAPHQL_CONTENT_TYPE = "application/json";

// Map a GraphQL error to the same error codes the HTTP path produces, so a
// caller handles auth or rate limiting identically on both transports.
// Servers put the machine-readable code in `extensions.code`; Linear-style
// APIs use `extensions.type`.
pub fn graphql_error_code(gqlerr: Value) []const u8 {
    const ext = h.getp(gqlerr, "extensions");

    var code: []const u8 = switch (h.getp(ext, "code")) {
        .string => |s| s,
        else => "",
    };
    if (code.len == 0) {
        code = switch (h.getp(ext, "type")) {
            .string => |s| s,
            else => "",
        };
    }

    const raw: []const u8 = std.ascii.allocUpperString(h.A(), code) catch "";

    if (std.mem.indexOf(u8, raw, "AUTH") != null or
        std.mem.indexOf(u8, raw, "FORBIDDEN") != null or
        std.mem.indexOf(u8, raw, "UNAUTHENTICATED") != null)
    {
        return "request_auth";
    }
    if (std.mem.indexOf(u8, raw, "RATELIMIT") != null or
        std.mem.indexOf(u8, raw, "RATE_LIMIT") != null or
        std.mem.indexOf(u8, raw, "TOO_MANY") != null)
    {
        return "request_ratelimit";
    }
    if (std.mem.indexOf(u8, raw, "BAD_USER_INPUT") != null or
        std.mem.indexOf(u8, raw, "VALIDATION") != null or
        std.mem.indexOf(u8, raw, "INVALID") != null)
    {
        return "request_invalid";
    }

    return "request_graphql";
}

// Build the request body for a GraphQL point.
//
// Variables come from the op's own arguments: a named variable binds to the
// like-named argument (`from`), and the input-object variable (empty `from`)
// takes the request data as a whole — which is what makes a generated
// create/update call look exactly like its REST equivalent.
pub fn graphql_body_util(ctx: *Context) Value {
    const gql = h.getp(ctx.point, "graphql");
    if (gql != .object) return h.vnull();

    // reqmatch/reqdata hold the caller's arguments for this operation; which
    // one depends on whether the op takes match or data input.
    var reqsrc = ctx.reqmatch;
    var datasrc = ctx.mtch;
    if (std.mem.eql(u8, ctx.op.input, "data")) {
        reqsrc = ctx.reqdata;
        datasrc = ctx.data;
    }
    if (reqsrc != .object) reqsrc = h.omap();
    if (datasrc != .object) datasrc = h.omap();

    const variables = h.omap();

    const varlist = h.getp(gql, "vars");
    if (varlist == .array) {
        for (varlist.array.data.items) |spec| {
            if (spec != .object) continue;

            const name: []const u8 = switch (h.getp(spec, "name")) {
                .string => |s| s,
                else => "",
            };
            if (name.len == 0) continue;

            const from: []const u8 = switch (h.getp(spec, "from")) {
                .string => |s| s,
                else => "",
            };

            if (from.len == 0) {
                // The input object IS the request body. Strip the action
                // selector, which is an SDK-side point discriminator, not
                // an API field.
                const body = h.omap();
                var it = reqsrc.object.iterator();
                while (it.next()) |kv| {
                    const key = kv.key_ptr.*;
                    if (!std.mem.eql(u8, key, "$action")) {
                        h.setp(body, key, kv.value_ptr.*);
                    }
                }
                h.setp(variables, name, body);
                continue;
            }

            // Only send variables the caller actually supplied: sending an
            // explicit null would clear a field on many APIs.
            var val = h.getp(reqsrc, from);
            if (h.is_noval(val) or h.is_null(val)) val = h.getp(datasrc, from);
            if (!h.is_noval(val) and !h.is_null(val)) {
                h.setp(variables, name, val);
            }
        }
    }

    const out = h.omap();
    h.setp(out, "query", h.getp(gql, "doc"));
    h.setp(out, "variables", variables);
    return out;
}

// Inspect a decoded GraphQL response body and record a failure when the
// server reported one. Returns true when an error was recorded.
//
// Partial data (`data` alongside `errors`) is treated as failure: the REST
// surface has no partial-success concept, and silently returning half an
// object would be worse than failing.
pub fn graphql_errors_util(ctx: *Context) bool {
    const result = ctx.result orelse return false;

    const kind: []const u8 = switch (h.getp(ctx.point, "kind")) {
        .string => |s| s,
        else => "",
    };
    if (!std.mem.eql(u8, kind, "graphql")) return false;

    const errors = h.getp(result.body, "errors");
    if (errors != .array or errors.array.data.items.len == 0) return false;

    const count = errors.array.data.items.len;
    const first = errors.array.data.items[0];

    var msg: []const u8 = switch (h.getp(first, "message")) {
        .string => |s| s,
        else => "",
    };
    if (msg.len == 0) msg = "graphql error";
    if (1 < count) msg = fmt("{s} (+{d} more)", .{ msg, count - 1 });

    result.err = ctx.make_error(graphql_error_code(first), fmt("graphql: {s}", .{msg}));
    result.ok = false;

    return true;
}

// prepare_auth IS GENERATED (src/cmp/zig/PrepareAuth_zig.ts), not templated.
//
// WHERE THE CREDENTIAL GOES IS A FACT ABOUT THE API. apidef resolves the
// security scheme's `in` and `name` into main.kit.info.security - joplin's
// says `in: "query", name: "token"` - and this file could hold only one
// answer, which was `const HEADER_AUTH = "authorization"`. So an
// apiKey-in-query API was sent a header it does not read and never sent the
// query parameter it does. Header, query and cookie need three different
// bodies; a component emits the one this API uses and nothing else.
//
// RE-EXPORTED, NOT REWIRED. Every caller keeps naming the same symbol:
// `Utility.prepare_auth` above, `make_spec_util`'s unqualified
// `try prepare_auth_util(ctx)`, and `sdk.utilmod.prepare_auth_util` - the
// path root.zig publishes and test/primary_utility_test.zig drives the
// shared corpus's `prepareAuth` section through. A file-scope const bound to
// the generated function is the whole of the binding change.
pub const prepare_auth_util = @import("prepare_auth.zig").prepare_auth_util;

// The two comptime FACTS the generated file decided: where this SDK puts its
// credential ("header" | "query" | "cookie" | "none"), and whether the scheme
// is genuine HTTP Basic. Re-exported on the same path as the function, so
// test/pipeline_test.zig can reach both as `sdk.utilmod.<name>` and skip the
// header-shape cases on an SDK that has no header credential to assert on.
pub const prepare_auth_placement = @import("prepare_auth.zig").PLACEMENT;
pub const prepare_auth_basic = @import("prepare_auth.zig").BASIC;

pub fn result_basic_util(ctx: *Context) ?*SdkResult {
    const response = ctx.response;
    const result = ctx.result;

    if (result != null and response != null) {
        const res = result.?;
        const resp = response.?;
        res.status = resp.status;
        res.status_text = resp.status_text;

        if (res.status >= 400) {
            const msg = fmt("request: {d}: {s}", .{ res.status, res.status_text });
            if (res.err) |prev| {
                res.err = ctx.make_error("request_status", fmt("{s}: {s}", .{ prev.msg, msg }));
            } else {
                res.err = ctx.make_error("request_status", msg);
            }
        } else if (resp.err) |rerr| {
            res.err = rerr;
        }
    }
    return result;
}

pub fn result_headers_util(ctx: *Context) ?*SdkResult {
    const response = ctx.response;
    const result = ctx.result;

    if (result) |res| {
        const headers: Value = if (response) |r| (switch (r.headers) {
            .object => r.headers,
            else => h.omap(),
        }) else h.omap();
        res.headers = headers;
    }
    return result;
}

pub fn result_body_util(ctx: *Context) ?*SdkResult {
    const response = ctx.response;
    const result = ctx.result;

    if (result) |res| {
        if (response) |resp| {
            const json = resp.json;
            const body = resp.body;
            if (json == .function and !h.is_noval(body)) {
                res.body = h.call_json(json);
            }
            if (resp.unreadable) {
                const sent: Value = if (ctx.spec) |sp| sp.headers else h.vnull();
                res.err = unreadable_body(ctx, res.status, res.headers, body, sent, res.err);
            }
        }
    }
    return result;
}

const PREVIEW_LENGTH = 160;

// A body that is not JSON. An HTTP failure keeps its own error, with the
// response described; otherwise the code tells a wrong content type from
// malformed JSON.
pub fn unreadable_body(
    ctx: *Context,
    status: i64,
    headers: Value,
    text: Value,
    sent: Value,
    failed: ?*err.UnivecError,
) *err.UnivecError {
    const ctype = body_header(headers, "content-type");
    const agent = clean_str_util(ctx, body_header(sent, "user-agent"));
    const detail = fmt("HTTP {d}, content-type {s}, user-agent {s}{s}", .{
        status,
        if (ctype.len == 0) "none" else ctype,
        if (agent.len == 0) "transport default" else agent,
        if (h.is_noval(text) or text == .null) "" else fmt(", body: {s}", .{body_preview(ctx, text)}),
    });

    if (failed) |f| {
        f.msg = fmt("{s} ({s})", .{ f.msg, detail });
        return f;
    }
    if (ctype.len == 0 or std.ascii.indexOfIgnoreCase(ctype, "json") != null) {
        return ctx.make_error("response_json_invalid", fmt("response: body is not valid JSON ({s})", .{detail}));
    }
    return ctx.make_error("response_content_type", fmt("response: expected JSON, got {s} ({s})", .{ ctype, detail }));
}

fn body_header(headers: Value, name: []const u8) []const u8 {
    if (headers == .object) {
        var it = headers.object.iterator();
        while (it.next()) |kv| {
            if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) {
                return switch (kv.value_ptr.*) {
                    .string => |sv| sv,
                    else => h.stringify(kv.value_ptr.*),
                };
            }
        }
    }
    return "";
}

// Cleaned whole: a secret the bound would split could leave its prefix.
fn body_preview(ctx: *Context, text: Value) []const u8 {
    const raw: []const u8 = switch (text) {
        .string => |sv| sv,
        else => h.stringify(text),
    };
    var spaced: std.ArrayList(u8) = .empty;
    var space = false;
    for (raw) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = spaced.items.len > 0;
            continue;
        }
        if (space) {
            spaced.append(h.A(), ' ') catch {};
            space = false;
        }
        spaced.append(h.A(), c) catch {};
    }
    const flat = clean_str_util(ctx, spaced.items);
    var points: usize = 0;
    var end: usize = 0;
    while (end < flat.len) : (end += 1) {
        if ((flat[end] & 0xC0) == 0x80) continue;
        if (points == PREVIEW_LENGTH) return fmt("{s}...", .{flat[0..end]});
        points += 1;
    }
    return flat;
}

// `$action` selects the point (see make_point_util); it is never an API
// field, so the body is a copy without it. The caller's map is left untouched.
fn strip_action(reqdata: Value) Value {
    return omit_keys(reqdata, &.{}, true);
}

// A header, cookie or query argument travels where prepare_headers_util or
// prepare_query_util sends it, so the body is built from the request data
// without it, unless the point marks it as a field the body keeps.
fn routed_arg_names(ctx: *Context) [][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "header", "cookie", "query" }) |kind| {
        for (call_args(ctx, kind)) |arg| {
            if (!field_arg(ctx, arg.name)) names.append(h.A(), arg.name) catch {};
        }
    }
    return names.toOwnedSlice(h.A()) catch &.{};
}

fn dropped(key: []const u8, routed: []const []const u8, action: bool) bool {
    if (action) return std.mem.eql(u8, key, "$action");
    for (routed) |name| {
        if (std.mem.eql(u8, name, key)) return true;
    }
    return false;
}

fn omit_keys(reqdata: Value, routed: []const []const u8, action: bool) Value {
    if (reqdata != .object) return reqdata;
    var found = false;
    var it = reqdata.object.iterator();
    while (it.next()) |kv| found = found or dropped(kv.key_ptr.*, routed, action);
    if (!found) return reqdata;
    const body = h.omap();
    var bit = reqdata.object.iterator();
    while (bit.next()) |kv| {
        const key = kv.key_ptr.*;
        if (!dropped(key, routed, action)) h.setp(body, key, kv.value_ptr.*);
    }
    return body;
}

pub fn transform_request_util(ctx: *Context) Value {
    const spec = ctx.spec;
    const point = ctx.point;

    if (spec) |sp| sp.step = "reqform";

    const reqdata = omit_keys(ctx.reqdata, routed_arg_names(ctx), false);

    const transform = h.to_map(h.getp(point, "transform"));
    if (h.is_noval(transform)) return strip_action(reqdata);

    const reqform = h.getp(transform, "req");
    if (h.is_noval(reqform)) return strip_action(reqdata);

    const store = h.jo(&.{.{ "reqdata", reqdata }});
    // transform now reports collected injection errors beside the value; .out
    // is what it used to return on its own, errors or not.
    const tres = vs.transform(h.A(), store, reqform) catch return strip_action(reqdata);
    return strip_action(tres.out);
}

fn field_arg(ctx: *Context, name: []const u8) bool {
    for ([_][]const u8{ "header", "cookie", "query" }) |kind| {
        const defs: Value = h.getpath(&.{ "args", kind }, ctx.point);
        if (defs != .array) continue;
        for (defs.array.data.items) |ad| {
            const n = h.getp(ad, "name");
            const f = h.getp(ad, "field");
            if (n == .string and std.mem.eql(u8, n.string, name) and f == .bool and f.bool) return true;
        }
    }
    return false;
}

pub fn transform_response_util(ctx: *Context) Value {
    const spec = ctx.spec;
    const result = ctx.result;
    const point = ctx.point;

    if (spec) |sp| sp.step = "resform";

    const res = result orelse return h.vnull();
    if (!res.ok) return h.vnull();

    const transform = h.to_map(h.getp(point, "transform"));
    if (h.is_noval(transform)) return h.vnull();

    const resform = h.getp(transform, "res");
    if (h.is_noval(resform)) return h.vnull();

    const store = h.jo(&.{
        .{ "ok", h.vbool(res.ok) },
        .{ "status", h.vnum(res.status) },
        .{ "statusText", h.vstr(res.status_text) },
        .{ "headers", res.headers },
        .{ "body", res.body },
        .{ "resdata", res.resdata },
        .{ "resmatch", res.resmatch },
    });

    const tres = vs.transform(h.A(), store, resform) catch return h.vnull();
    const resdata = tres.out;
    res.resdata = resdata;
    return resdata;
}

// ============================================================================
// fetcher (default transport)
// ============================================================================

fn defaultFetcherCall(_: *anyopaque, opctx: *Context, url: []const u8, fetchdef: Value) E!Value {
    return fetcher_util(opctx, url, fetchdef);
}

pub fn fetcher_util(ctx: *Context, fullurl: []const u8, fetchdef: Value) E!Value {
    const client = ctx.client orelse return ctx.fail("fetch_no_client", "Expected context client.");

    const mode = client.mode;
    if (!std.mem.eql(u8, mode, "live")) {
        return ctx.fail("fetch_mode_block", fmt("Request blocked by mode: \"{s}\" (URL was: \"{s}\")", .{ mode, fullurl }));
    }

    const options = client.options_map();
    if (h.veq(h.getpath(&.{ "feature", "test", "active" }, options), h.vbool(true))) {
        return ctx.fail("fetch_test_block", fmt("Request blocked as test feature is active (URL was: \"{s}\")", .{fullurl}));
    }

    const sys_fetch = h.getpath(&.{ "system", "fetch" }, options);

    if (h.is_noval(sys_fetch)) {
        return default_http_fetch(ctx, fullurl, fetchdef);
    }

    if (sys_fetch == .function) {
        const out = h.call_vfn(sys_fetch, h.ja(&.{ h.vstr(fullurl), fetchdef }));
        if (h.get_str(out, "__err__")) |msg| {
            return ctx.fail("fetch_system", msg);
        }
        return out;
    }

    return ctx.fail("fetch_invalid", "system.fetch is not a valid function");
}

fn default_http_fetch(ctx: *Context, fullurl: []const u8, fetchdef: Value) E!Value {
    _ = fetchdef;
    // Live HTTP transport. The generated test suite runs entirely against the
    // offline mock (the `test` feature), so this path is not exercised by
    // tests; a real deployment injects `system.fetch`. A std.http.Client
    // implementation can be wired here.
    return ctx.fail("fetch_transport", fmt("live transport unavailable (URL was: \"{s}\")", .{fullurl}));
}
