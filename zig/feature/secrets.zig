// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The zig port of
// tm/ts/src/feature/secrets/SecretsFeature.ts, following the GO port's
// structure (feature/secrets_feature.go) - same contract, zig idiom.
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider - a `memory` store named `options` - so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
// When the option is unset the remaining providers (env, dotenv, a vault)
// are asked in order, and moving a credential from code to a vault becomes
// a configuration change.
//
// MISS vs ERROR (sekreto's invariant, and STRUCTURAL in this port: a lookup
// answers `.ok = null` for a miss and `.err = message` for a failure): a
// provider MISS falls through - the op proceeds, unauthenticated if nothing
// else supplies a credential. A provider ERROR (unreachable vault, bad
// creds) must FAIL the op: a broken vault never degrades into an
// unauthenticated request.
//
// WHERE RESOLUTION HAPPENS, and why it is not the PreSpec hook. zig's
// `Feature.VTable.dispatch` returns void (core/types.zig), so a hook cannot
// fail an operation the way ts's awaited hook rejection can - and `direct()`
// / `graphql()` run no feature hooks at all (Main.fragment.zig raw_request
// calls sdkUtility.fetch directly). So, exactly as in the go and rust ports,
// resolution happens at the TRANSPORT SEAM: the one place every wire path
// crosses. The wrapper refuses to send while the last resolution stands
// failed, which is fail-closed for the entity pipeline and the raw paths
// alike, with one implementation. The wrapper is installed FIRST, before the
// chain is built, so a construction failure of any kind still leaves the
// gate in place.
//
// WHERE THE CREDENTIAL LIVES, and why it is not the options map. The ts
// reference writes `options.apikey`; this port does NOT. `options_map()`
// deep-clones on every prepare_auth call and the root options Value is
// shared by every context, so a feature that mutated it would be visible
// everywhere at once and would defeat the `auth: null` suppression pin. The
// resolved credential is held in FEATURE STATE and written into each
// request's header at the transport, the same construction prepare_auth
// uses (options.auth.prefix), so the wire is identical and the options map
// stays frozen after construction.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when
// a response status in `exchange.statuses` (401) says it is spent the
// wrapper buys another and retries the same request once. Test mode buys
// nothing and answers with a deterministic fake token.
//
// THE EXCHANGE'S TRANSPORT OF LAST RESORT. The SDK's own default_http_fetch
// (core/utility.zig) has no live HTTP client - a real deployment injects
// `system.fetch`. The exchange uses `system.fetch` when there is one; when
// there is not, it uses the vendored sekreto plugins' own HTTP round-trip
// (`sekretoplugins.httpjson.fetchjson`: std.http.Client + std.crypto.tls,
// no external dependency), which the generated feature/secrets/plugins.zig
// always exports. That keeps the HTTP transport INSIDE the gated feature:
// an SDK without secrets links none of it. Deliberately NOT the SDK
// transport, which this feature wraps - sending the token request back
// through it would recurse on the first expiry.
//
// THE ENVIRONMENT. zig 0.16 removed std.os.environ: a library cannot read
// the process environment by itself, and sekreto's Config asks for the map.
// The SDK builds it from the block std's startup code hands to
// `std.Io.Threaded.global_single_threaded` (core/mem.zig's io) - present in
// every build mode and needing no libc - and an application that holds
// `init.environ_map` can hand its own in through `SecretsFeature
// .set_environ` before constructing the client (the test suite does).
//
// THREADING: the zig SDK is single-threaded by construction (one process
// arena, one Utility mutated in place by every wrapping feature), so go's
// mutex/channel machinery for shared in-flight resolutions and purchases
// collapses to plain fields here, as it does in rust.
//
// Every refusal this feature raises carries the error code `secrets`, so a
// caller can tell a secrets failure from a transport failure.

const std = @import("std");
const h = @import("../core/helpers.zig");
const mem = @import("../core/mem.zig");
const err = @import("../core/error.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

// NAMED BUILD MODULES, not paths: the vendored trees under feature/secrets/
// are the roots of the `sekreto` and `sekretoplugins` modules build.zig
// declares (Main_zig FEATURE_MODULES) - only when this feature is active,
// which is also the only time anything analyses this file. A path import
// would put the vendored files in two modules at once ("file exists in
// multiple modules").
const sekreto = @import("sekreto");
const sekplugins = @import("sekretoplugins");

const Value = h.Value;
const Allocator = std.mem.Allocator;
const Context = types.Context;
const Feature = types.Feature;
const Fetcher = types.Fetcher;
const E = err.E;

const pv = sekreto.plugin.value;
const Environ = std.process.Environ;

const ERRCODE = "secrets";
const HEADER_AUTH = "authorization";

/// The access-token exchange, normalised once at init. Null when off, so
/// every later decision is one optional check.
const Exchange = struct {
    path: []const u8,
    method: []const u8,
    request: []const u8,
    response: []const u8,
    statuses: []const i64,
    retries: i64,
};

/// Everything the transport wrapper needs, heap-allocated once per feature
/// so the wrapper's closure context and the feature share it.
pub const State = struct {
    /// The root context this feature was initialised against: its `client`
    /// carries the mode (test mode buys nothing) and its `options` are the
    /// resolved live options, READ-ONLY here - see the header note.
    rootctx: ?*Context = null,
    liveopts: Value = .{ .null = {} },

    secretname: []const u8 = "apikey",
    cache: bool = true,
    exchange: ?Exchange = null,

    /// The LIVE chain, for callers who want arbitrary secrets or redaction.
    sek: ?*sekreto.Sekreto = null,

    /// The environment map the chain's `env` provider reads. Owned here so
    /// the `Config` pointer into it stays valid for the client's life.
    envmap: Environ.Map = undefined,

    /// The RESOLVED credential, injected into each request at the transport
    /// seam - never written into the shared options map.
    cred: []const u8 = "",
    /// The refresh token the chain resolved, when exchanging.
    refresh: []const u8 = "",

    /// A settled SUCCESSFUL resolution. Kept only while caching is on
    /// (`cache: false` means every request asks the chain again), and never
    /// set by a FAILURE - a transient vault outage must not poison the
    /// client permanently.
    resolved: bool = false,

    /// A chain that could not be built. The transport gate refuses to send
    /// while this stands, which keeps a misconfigured chain fail-closed
    /// rather than silently unauthenticated.
    initerr: ?[]const u8 = null,
};

pub const SecretsFeature = struct {
    name: []const u8 = "secrets",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },
    state: *State,

    pub fn make() Feature {
        const self = h.A().create(SecretsFeature) catch unreachable;
        const state = h.A().create(State) catch unreachable;
        state.* = .{};
        self.* = .{ .state = state };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// The process environment the `env` provider reads, handed in by the
    /// application - a zig 0.16 `main(init)` holds it as `init.environ_map`.
    /// Null (the default) means the SDK builds one itself from std's startup
    /// block. Read at the NEXT construction: set it before `new()`.
    pub fn set_environ(map: ?*const Environ.Map) void {
        given_environ = map;
    }

    /// The resolved credential (empty when none) - the state the transport
    /// injects. Read here rather than from the options map, which this
    /// feature never mutates.
    pub fn credential(self: *SecretsFeature) []const u8 {
        return self.state.cred;
    }

    /// The construction failure the gate is refusing on, if any.
    pub fn init_error(self: *SecretsFeature) ?[]const u8 {
        return self.state.initerr;
    }

    /// The LIVE sekreto instance (the zig spelling of ts's public sekreto()
    /// accessor). Never a clone: it holds provider state and the cache.
    pub fn sek(self: *SecretsFeature) ?*sekreto.Sekreto {
        return self.state.sek;
    }

    /// A transparent read through the chain: the value, or sekreto's own
    /// message (a miss is `sekreto: unknown secret: <name>`).
    pub fn get(self: *SecretsFeature, name: []const u8) sekreto.Answer([]const u8) {
        const s = self.state.sek orelse return .{ .err = "secrets: no provider chain" };
        return s.get(name) catch .{ .err = "secrets: out of memory" };
    }

    /// A directed read: only the named store is asked.
    pub fn getfrom(self: *SecretsFeature, store: []const u8, name: []const u8) sekreto.Answer([]const u8) {
        const s = self.state.sek orelse return .{ .err = "secrets: no provider chain" };
        return s.getfrom(store, name) catch .{ .err = "secrets: out of memory" };
    }

    /// Every value the chain has ever resolved, replaced in `text`.
    pub fn redact(self: *SecretsFeature, text: []const u8) []const u8 {
        const s = self.state.sek orelse return text;
        return sekreto.redact(h.A(), text, s.seen.items) catch text;
    }

    /// Resolve now, rather than at the next request. Returns the failure
    /// message when the chain refuses.
    pub fn resolve_now(self: *SecretsFeature) ?[]const u8 {
        const ctx = self.state.rootctx orelse return null;
        resolve(self.state, ctx) catch {
            const e = ctx.take_err();
            return if (e) |pe| pe.msg else "secrets: resolution failed";
        };
        return null;
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

    // Sync by feature contract: build the chain, never look anything up
    // here.
    fn vinit(p: *anyopaque, ctx: *Context, options: Value) void {
        const self = self_of(p);
        self.options = options;
        self.active = sup.fopt_bool(options, "active", false);
        if (!self.active) return;

        const st = self.state;
        st.rootctx = ctx;
        st.liveopts = ctx.options;

        // Wrap the transport FIRST. The fail-closed gate needs the seam
        // whenever the feature is active - hooks cannot fail an operation
        // and the raw paths run none - and the exchange additionally needs
        // to SEE responses, since expiry is only ever discovered from one.
        // Installed before the chain is built so that nothing below can
        // leave an active feature with an unguarded transport.
        const util = ctx.util();
        const w = h.A().create(WrapCtx) catch unreachable;
        w.* = .{ .inner = util.fetcher, .state = st };
        util.fetcher = .{ .ctx = @ptrCast(w), .call = wrapCall };

        st.secretname = sup.fopt_str(options, "name", "apikey");
        st.cache = sup.fopt_bool(options, "cache", true);

        const xopts = sup.fopt_map(options, "exchange");
        if (sup.fopt_bool(xopts, "active", false)) {
            var statuses: std.ArrayList(i64) = .empty;
            const raw = sup.fopt_list(xopts, "statuses");
            if (raw == .array) {
                for (raw.array.data.items) |v| statuses.append(h.A(), h.to_int(v)) catch {};
            }
            if (0 == statuses.items.len) statuses.append(h.A(), 401) catch {};
            st.exchange = .{
                .path = sup.fopt_str(xopts, "path", "auth/token"),
                .method = sup.fopt_str(xopts, "method", "POST"),
                .request = sup.fopt_str(xopts, "request", "refresh_token"),
                .response = sup.fopt_str(xopts, "response", "access_token"),
                .statuses = statuses.items,
                .retries = sup.fopt_int(xopts, "retries", 1),
            };
        }

        const alloc = h.A();

        // The explicit credential, when set, is the first store in the
        // chain.
        //
        // WHICH option that is depends on the exchange. Without one, the
        // secret being resolved IS the credential the transport sends, so
        // `apikey` is it. With one, the secret is a REFRESH token and
        // `apikey` means the opposite thing - an access token the caller
        // already holds - so the explicit seat belongs to
        // `exchange.refresh`, and apikey is left alone to serve as the
        // starting access token (see resolve_once).
        const explicit: []const u8 = if (st.exchange == null)
            (h.get_str(st.liveopts, "apikey") orelse "")
        else
            sup.fopt_str(xopts, "refresh", "");

        var specs: std.ArrayList(sekreto.ProviderSpec) = .empty;

        if (0 != explicit.len) {
            const keyed = sekreto.envkey(alloc, st.secretname, "") catch
                sekreto.Answer([]const u8){ .err = "secrets: out of memory" };
            switch (keyed) {
                .ok => |key| {
                    const values = alloc.alloc(sekreto.KeyValue, 1) catch unreachable;
                    values[0] = .{ .key = key, .value = explicit };
                    specs.append(alloc, .{ .kind = "memory", .name = "options", .values = values }) catch {};
                },
                .err => |message| st.initerr = message,
            }
        }

        const providers = sup.fopt_list(options, "providers");
        if (providers == .array) {
            for (providers.array.data.items) |entry| {
                switch (entry) {
                    // A provider written as a callable (see FuncProvider).
                    .function => {
                        const index = func_providers.items.len;
                        func_providers.append(alloc, entry) catch unreachable;
                        specs.append(alloc, .{
                            .kind = FUNC_KIND,
                            .name = "custom",
                            .path = std.fmt.allocPrint(alloc, "{d}", .{index}) catch "0",
                        }) catch {};
                    },
                    // A spec map: the same keys every port's spec uses,
                    // read back through sekreto's own decoder.
                    .object => specs.append(alloc, sekreto.provider.specof(to_plugin_value(entry))) catch {},
                    // FAIL CLOSED, never drop. An entry that is neither a
                    // callable nor a spec (a bare "hashicorp" where a spec
                    // map was meant) must not leave the chain quietly
                    // shorter than the options say: sekreto's own wording
                    // lands in the init-failure gate, which refuses to send.
                    // The zig ProviderSpec is a typed struct, so the refusal
                    // is raised at this arm, as the go and rust ports do.
                    else => {
                        if (st.initerr == null) {
                            st.initerr = std.fmt.allocPrint(
                                alloc,
                                "sekreto: not a provider or a provider spec: {s}",
                                .{h.stringify(entry)},
                            ) catch "sekreto: not a provider or a provider spec";
                        }
                    },
                }
            }
        }

        if (st.initerr != null) return;

        // The plugin DEFINITIONS the model selected, from the GENERATED
        // module root (feature/secrets/plugins.zig, Config_zig
        // FeaturePlugins). Upstream sekreto's contract since the registry
        // was retired: a kind not passed in is unknown to this Sekreto, so
        // the model's choice of plugin groups IS the SDK's provider
        // vocabulary. Plus this feature's own callable kind.
        var defs: std.ArrayList(sekreto.Definition) = .empty;
        for (sekplugins.SELECTED) |d| defs.append(alloc, d) catch {};
        defs.append(alloc, FUNC_DEFINITION) catch {};

        st.envmap = environ_map(alloc);

        const built = sekreto.Sekreto.init(alloc, .{ .io = h.IO(), .env = &st.envmap }, .{
            .providers = specs.items,
            .plugins = defs.items,
            .cache = st.cache,
        }) catch sekreto.Answer(*sekreto.Sekreto){ .err = "secrets: out of memory" };

        switch (built) {
            .ok => |made| st.sek = made,
            // Init cannot fail construction the way ts's throwing init does;
            // the transport gate refuses to send instead.
            .err => |message| st.initerr = message,
        }
    }

    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        // The model declares a PreSpec hook (as go's does); resolution
        // happens at the transport instead, for the reasons in the header.
        _ = p;
        _ = name;
        _ = ctx;
    }

    fn self_of(p: *anyopaque) *SecretsFeature {
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

// ---- the environment -----------------------------------------------------

/// An application-supplied environment map (SecretsFeature.set_environ).
var given_environ: ?*const Environ.Map = null;

/// The map the chain's `env` provider reads: the application's when it gave
/// one, else the process environment as std's startup code recorded it on
/// the global single-threaded Io (which core/mem.zig uses for everything
/// else). Empty - never a crash - on a target where std records nothing.
fn environ_map(alloc: Allocator) Environ.Map {
    if (given_environ) |given| {
        return given.clone(alloc) catch Environ.Map.init(alloc);
    }
    const process_environ = mem.threaded().environ.process_environ;
    return Environ.createMap(process_environ, alloc) catch Environ.Map.init(alloc);
}

// ---- a provider written as a callable ------------------------------------

/// The kind name of a provider given as a plain callable in `providers`.
const FUNC_KIND = "sdkfunc";

/// The callables handed in through `providers`, in registration order.
///
/// MODULE-GLOBAL, for the reason sekreto's own port keeps its `building`
/// slot global: a definition's `define` is a bare function pointer with no
/// context, and voxgig/plugin option values are strings and numbers, not
/// pointers - so the spec carries the callable's INDEX here (in `path`)
/// and `makefunc` reads it back. Append-only for the life of the process.
var func_providers: std.ArrayList(Value) = .empty;

/// A provider given as a plain callable.
///
/// A live provider cannot travel inside a Value - the SDK union is a CLOSED
/// data union, and widening the vendored struct library to carry SDK
/// objects would be wrong - and a zig provider kind is a comptime
/// definition, so go's `providers: [&customProvider{...}]` has no direct
/// translation. This is the Value-shaped answer (the same one rust gives):
/// the callable is handed the secret NAME and answers
///
///   a string                       -> a HIT
///   null / no value                -> a MISS, the chain continues
///   { "__err__": "..." }           -> an ERROR, which fails the operation
///
/// The miss/error split is the whole point: conflating them turns a broken
/// vault into a silent unauthenticated request. The `__err__` shape is the
/// one the Value seams already speak (system.fetch signals a transport
/// failure the same way).
const FuncProvider = struct {
    f: Value,

    pub fn lookup(self: *FuncProvider, alloc: Allocator, name: []const u8) Allocator.Error!sekreto.Found {
        const out = h.call_vfn(self.f, h.vstr(name));
        return switch (out) {
            .string => |s| .{ .ok = try alloc.dupe(u8, s) },
            .object => if (h.get_str(out, "__err__")) |message|
                .{ .err = try alloc.dupe(u8, message) }
            else
                .{ .ok = null },
            else => .{ .ok = null },
        };
    }

    pub fn describe(_: *FuncProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return alloc.dupe(u8, "custom");
    }

    pub fn deinit(_: *FuncProvider, _: Allocator) void {}
};

fn makefunc(alloc: Allocator, config: sekreto.Config, spec: sekreto.ProviderSpec) Allocator.Error!sekreto.Answer(sekreto.Provider) {
    _ = config;
    const index = std.fmt.parseInt(usize, spec.path, 10) catch func_providers.items.len;
    if (index >= func_providers.items.len) {
        return .{ .err = try sekreto.fail(alloc, "secrets: no callable provider at {s}", .{spec.path}) };
    }
    return .{ .ok = try sekreto.provide(alloc, FuncProvider, .{ .f = func_providers.items[index] }) };
}

const FUNC_DEFINITION = sekreto.providerplugin(FUNC_KIND, makefunc);

// ---- SDK Value -> voxgig/plugin Value ------------------------------------

/// SDK Value -> voxgig/plugin Value, so an option map can be handed to
/// sekreto's `specof`. The two are different types on purpose: the plugin
/// value is an arena-allocated pointer tree the host owns for the life of
/// the process; the SDK's is the vendored struct library's reference-stable
/// union. Callables have no counterpart and become null.
fn to_plugin_value(v: Value) *pv.Value {
    return switch (v) {
        .bool => |b| pv.vbool(b),
        .integer => |n| pv.vnum(@floatFromInt(n)),
        .float => |f| pv.vnum(f),
        .string => |s| pv.vstr(pv.dupe(s)),
        .number_string => |s| pv.vstr(pv.dupe(s)),
        .array => |list| blk: {
            const out = pv.vlist();
            for (list.data.items) |item| pv.push(out, to_plugin_value(item));
            break :blk out;
        },
        .object => |m| blk: {
            const out = pv.vmap();
            var it = m.iterator();
            while (it.next()) |kv| pv.set(out, kv.key_ptr.*, to_plugin_value(kv.value_ptr.*));
            break :blk out;
        },
        else => pv.vnull(),
    };
}

// ---- the transport seam --------------------------------------------------

const WrapCtx = struct {
    inner: Fetcher,
    state: *State,
};

fn wrapCall(p: *anyopaque, ctx: *Context, url: []const u8, fetchdef: Value) E!Value {
    const w: *WrapCtx = @ptrCast(@alignCast(p));
    return transport(w.state, ctx, url, fetchdef, w.inner);
}

fn transport(st: *State, ctx: *Context, url: []const u8, fetchdef: Value, inner: Fetcher) E!Value {
    // Fail-closed, at the ONE seam every wire path crosses. Entity ops,
    // direct(), graphql() and the exchange retries all come through here,
    // so resolving HERE is what gives the raw paths - which run no feature
    // hooks at all - the same credential the entity pipeline gets. A
    // provider ERROR refuses the request with the provider's own message;
    // never an unauthenticated send.
    if (st.initerr) |message| return ctx.fail(ERRCODE, message);

    try resolve(st, ctx);

    // Inject the resolved credential into THIS request's header. The
    // header was built by prepare_auth from the options apikey; the
    // chain-resolved value lives in feature state instead, so the wrapper
    // writes it here - same construction, same suppression rules - and the
    // shared options map stays untouched. A MISS leaves whatever
    // prepare_auth built, which is nothing.
    if (0 != st.cred.len) reauth(st, fetchdef, st.cred);

    if (st.exchange == null) return inner.invoke(ctx, url, fetchdef);

    return with_refresh(st, ctx, url, fetchdef, inner);
}

// One resolution, shared by every request. A settled SUCCESS is kept only
// when caching is on; a FAILURE is never kept, so a transient vault outage
// never poisons the client permanently - the next operation asks again.
fn resolve(st: *State, ctx: *Context) E!void {
    if (st.initerr) |message| return ctx.fail(ERRCODE, message);
    if (st.resolved) return;

    resolve_once(st, ctx) catch |e| {
        st.resolved = false;
        return e;
    };

    if (st.cache) st.resolved = true;
}

fn resolve_once(st: *State, ctx: *Context) E!void {
    const s = st.sek orelse return;

    const found = s.trysecret(st.secretname) catch
        return ctx.fail(ERRCODE, "secrets: out of memory");

    const value: ?[]const u8 = switch (found) {
        // A provider ERROR fails the op (via the transport gate); only a
        // MISS falls through. The message is copied out: sekreto owns and
        // replaces it on the next failure.
        .err => |message| return ctx.fail(ERRCODE, h.A().dupe(u8, message) catch message),
        .ok => |v| v,
    };

    if (st.exchange == null) {
        // An UNCACHED miss after an earlier hit is a revocation: the chain
        // now says no provider has the secret, so the resolved value must
        // not keep going out on the wire. (An explicit apikey OPTION is
        // never lost here - it seats FIRST in the chain as a memory
        // provider, so the chain HITS while one is set and the miss branch
        // is unreachable.)
        st.cred = value orelse "";
        return;
    }

    // Exchanging: what the chain resolved is the REFRESH token, kept for
    // every later purchase. A miss is not fatal here - an explicit `apikey`
    // may already hold a usable access token, and the API is what gets to
    // say whether it does.
    st.refresh = value orelse "";

    if (0 == st.cred.len) {
        // A starting access token supplied as the OPTION: read from the
        // frozen options map (no feature ever writes it).
        st.cred = h.get_str(st.liveopts, "apikey") orelse "";
    }
    if (0 != st.cred.len) {
        // A starting access token was supplied. Spend it: if it is stale
        // the API answers with an expiry status and the wrapper buys
        // another, which is the same path expiry takes anyway.
        return;
    }

    _ = try buy(st, ctx);
}

// Buy a token and try the request again when the API says the current one
// is spent.
//
// The retry rewrites the authorization header IN PLACE on the fetchdef,
// because the header was built by the synchronous prepare_auth before this
// request left and carries the token that just failed. Rebuilt the way
// prepare_auth builds it, from the same options.auth.prefix, so the two
// cannot drift.
fn with_refresh(st: *State, ctx: *Context, url: []const u8, fetchdef: Value, inner: Fetcher) E!Value {
    // `auth: null` is the documented way to send NO credential, and
    // prepare_auth honours it by removing the header. A refusal of a
    // deliberately unauthenticated request is not an expired token and
    // cannot be fixed by buying one - retrying would transmit exactly the
    // credential the caller suppressed.
    if (!auth_active(st.liveopts)) return inner.invoke(ctx, url, fetchdef);

    const max = if (st.exchange) |x| x.retries else 0;
    var attempt: i64 = 0;

    while (true) {
        // The credential THIS attempt goes out with, captured before it
        // leaves: it is what tells a stale refusal apart from a fresh one.
        const used = st.cred;

        const res = try inner.invoke(ctx, url, fetchdef);

        if (attempt >= max or !spent(st, res)) return res;

        // A token another request already bought is spent before buying: a
        // second exchange for a token that is already fresh is wasted, and
        // on a provider that invalidates the previous credential on
        // issuance it breaks the first request's own retry.
        const current = st.cred;
        const token: []const u8 = if (0 != current.len and !std.mem.eql(u8, current, used))
            current
        else
            buy(st, ctx) catch {
                // The purchase failed: answer with the API's own refusal
                // rather than this one. The caller asked for data, and the
                // refusal is the more useful of the two - the exchange error
                // is a symptom. The parked error must not outlive this
                // decision, or a SUCCESSFUL return would carry a pending
                // failure into the next pipeline stage.
                _ = ctx.take_err();
                return res;
            };

        reauth(st, fetchdef, token);
        attempt += 1;
    }
}

fn spent(st: *State, res: Value) bool {
    const status = sup.fres_status(res) orelse return false;
    const x = st.exchange orelse return false;
    for (x.statuses) |s| {
        if (s == status) return true;
    }
    return false;
}

// Is auth ACTIVE? Read the raw map rather than through getp, which applies
// the Group A rule and reads a stored null as "no value" - so it cannot tell
// an absent auth from a suppressed one, and only the latter is a
// suppression. Same reading make_options uses to preserve `auth: null`.
fn auth_active(options: Value) bool {
    return switch (options) {
        .object => |m| if (m.get("auth")) |a| a == .object else false,
        else => false,
    };
}

fn reauth(st: *State, fetchdef: Value, token: []const u8) void {
    const headers = h.getp(fetchdef, "headers");
    if (headers != .object) return;

    // Suppressed auth means NO header, the same answer prepare_auth gives.
    // Reached defensively - with_refresh does not retry at all when auth is
    // suppressed - but this is the function that writes the credential, so
    // it is where the rule has to hold.
    if (!auth_active(st.liveopts)) {
        h.del_prop(headers, h.vstr(HEADER_AUTH));
        return;
    }

    const prefix: []const u8 = switch (h.getpath(&.{ "auth", "prefix" }, st.liveopts)) {
        .string => |s| s,
        else => "",
    };

    // Empty prefix (a raw apiKey credential) must not add a leading space.
    if (0 == prefix.len) {
        h.setp(headers, HEADER_AUTH, h.vstr(token));
    } else {
        h.setp(headers, HEADER_AUTH, h.vstr(std.fmt.allocPrint(h.A(), "{s} {s}", .{ prefix, token }) catch token));
    }
}

// ---- the exchange --------------------------------------------------------

fn is_live(st: *State) bool {
    const ctx = st.rootctx orelse return true;
    const client = ctx.client orelse return true;
    return std.mem.eql(u8, client.mode, "live");
}

// Buy an access token with the refresh token. The slot is a plain field
// (single-threaded SDK): the next expiry buys a fresh token rather than
// replaying this result.
fn buy(st: *State, ctx: *Context) E![]const u8 {
    const x = st.exchange orelse return ctx.fail(ERRCODE, "secrets: no exchange configured");

    // TEST MODE BUYS NOTHING. The test feature replaces the transport so
    // no request leaves the process; an exchange here would be the one
    // HTTP call it could not stop, and it would need a live token endpoint
    // for a suite whose whole point is not needing one. A deterministic,
    // obviously-fake token instead - the same answer make_options gives a
    // required server variable, for the same reason.
    if (!is_live(st)) {
        const token = std.fmt.allocPrint(h.A(), "test-{s}", .{x.response}) catch "test-token";
        st.cred = token;
        return token;
    }

    if (0 == st.refresh.len) {
        return ctx.fail(ERRCODE, std.fmt.allocPrint(
            h.A(),
            "secrets: no refresh token: the provider chain has no '{s}', and feature.secrets.exchange.refresh is unset",
            .{st.secretname},
        ) catch "secrets: no refresh token");
    }

    const options: Value = if (ctx.client) |client| client.options_map() else st.liveopts;

    // The token endpoint is RELATIVE to the base, which already carries
    // whatever account or tenant segment the server URL declares.
    const base = std.mem.trimEnd(u8, h.get_str(options, "base") orelse "", "/");
    const path = std.mem.trimStart(u8, x.path, "/");
    const url = std.fmt.allocPrint(h.A(), "{s}/{s}", .{ base, path }) catch x.path;

    // The body is SERIALISED, never concatenated: a refresh token (or a
    // configured request-field name) carrying a quote, backslash or newline
    // must arrive as that literal value, not as malformed JSON.
    const body = h.jsonify_compact(h.jo(&.{.{ x.request, h.vstr(st.refresh) }}));

    const sysfetch = h.getpath(&.{ "system", "fetch" }, options);

    var res: Value = undefined;
    if (sysfetch == .function) {
        // The caller's transport, when there is one - the same seam the SDK
        // itself uses for every request.
        res = h.call_vfn(sysfetch, h.ja(&.{
            h.vstr(url),
            h.jo(&.{
                .{ "method", h.vstr(x.method) },
                .{ "headers", h.jo(&.{.{ "content-type", h.vstr("application/json") }}) },
                .{ "body", h.vstr(body) },
            }),
        }));
        if (h.get_str(res, "__err__")) |message| return ctx.fail(ERRCODE, message);
    } else {
        // No custom transport supplied - the ordinary case (make_options
        // leaves system.fetch unset, and the SDK's default transport has no
        // HTTP client). See raw_exchange_fetch.
        res = try raw_exchange_fetch(ctx, url, x.method, body);
    }

    const status = h.to_int(h.getp(res, "status"));
    if (200 > status or 300 <= status) {
        return ctx.fail(ERRCODE, std.fmt.allocPrint(
            h.A(),
            "secrets: token exchange failed: {d} from {s}",
            .{ status, url },
        ) catch "secrets: token exchange failed");
    }

    const jf = h.getp(res, "json");
    const payload: Value = if (jf == .function) h.call_json(jf) else h.getp(res, "body");

    const token = h.get_str(payload, x.response) orelse "";
    if (0 == token.len) {
        return ctx.fail(ERRCODE, std.fmt.allocPrint(
            h.A(),
            "secrets: token exchange returned no '{s}' field from {s}",
            .{ x.response, url },
        ) catch "secrets: token exchange returned no token");
    }

    st.cred = token;
    return token;
}

// The token-exchange transport of last resort: the vendored sekreto
// plugins' own HTTP round-trip (std.http.Client + std TLS, always exported
// by the generated feature/secrets/plugins.zig), answering in the shape the
// system.fetch seam promises ("status" + "json"). It exists so an exchange
// works with ordinary SDK options - requiring a custom transport for the
// COMMON case would reject every live token purchase before a request was
// made. It does NOT go through sekreto's checkaddr: a plaintext loopback
// token endpoint is the caller's business, exactly as it is for go's
// net/http path.
fn raw_exchange_fetch(ctx: *Context, url: []const u8, method_name: []const u8, body: []const u8) E!Value {
    const method = std.meta.stringToEnum(std.http.Method, method_name) orelse .POST;
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    const result = sekplugins.httpjson.fetchjson(h.A(), h.IO(), method, url, &headers, body) catch
        return ctx.fail(ERRCODE, "secrets: out of memory");

    return switch (result) {
        // sekreto's own message ("sekreto: cannot reach <url>: <reason>").
        .err => |message| ctx.fail(ERRCODE, message),
        .ok => |response| h.jo(&.{
            .{ "status", h.vnum(@intCast(response.status)) },
            .{ "statusText", h.vstr("") },
            .{ "headers", h.omap() },
            .{ "json", h.json_thunk(from_std_json(response.body)) },
        }),
    };
}

// std.json.Value (what fetchjson parses) -> the SDK Value.
fn from_std_json(v: ?std.json.Value) Value {
    const value = v orelse return h.vnull();
    return switch (value) {
        .null => h.vnull(),
        .bool => |b| h.vbool(b),
        .integer => |n| h.vnum(n),
        .float => |f| h.vfloat(f),
        .number_string => |s| h.vstr(h.A().dupe(u8, s) catch s),
        .string => |s| h.vstr(h.A().dupe(u8, s) catch s),
        .array => |items| blk: {
            const out = h.olist();
            for (items.items) |item| out.array.append(from_std_json(item)) catch {};
            break :blk out;
        },
        .object => |m| blk: {
            const out = h.omap();
            var it = m.iterator();
            while (it.next()) |kv| {
                h.setp(out, h.A().dupe(u8, kv.key_ptr.*) catch kv.key_ptr.*, from_std_json(kv.value_ptr.*));
            }
            break :blk out;
        },
    };
}
