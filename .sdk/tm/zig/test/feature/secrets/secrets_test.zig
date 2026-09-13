// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
// the zig port of tm/ts/test/feature/secrets/Secrets.test.ts, following the
// go suite's shape (tm/go/test/feature/secrets/secrets_feature_test.go).
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because the feature places it FIRST in the provider
// chain (a `memory` store named `options`) - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic. With
// the feature inactive nothing changes at all. With it active and the
// option unset, the chain supplies the credential instead.
//
// EVERY CLIENT HERE IS LIVE, and the thing counted is `system.fetch` - the
// real transport the whole fetcher chain ends at. That is deliberate, and
// it is the mistake this file exists to avoid: under `test_sdk` the test
// feature REPLACES the transport with its own in-memory mock, so a counter
// hung off `system.fetch` is never reached, and "no request was sent" would
// hold for a healthy SDK carrying no secrets feature at all. An assertion
// that cannot fail pins no rule. So each fail-closed case proves its own
// counter FIRST, with the same construction and a WORKING provider: one
// request must reach `system.fetch` carrying the resolved credential. Only
// then does a zero from the broken provider mean REFUSED rather than
// UNWIRED. And the refusal is matched on the PROVIDER'S OWN message, so an
// unrelated failure cannot stand in for fail-closed.
//
// BOTH WIRE PATHS. The entity pipeline is driven through a REAL generated
// entity op, found by comptime reflection over the client's accessors (the
// zig spelling of go's reflect-based driver), and the raw paths -
// `direct()` and `graphql()`, which run NO feature hooks - are driven too:
// for them the transport gate is the only place resolution can happen.
//
// NO ENVIRONMENT VARIABLES ARE SET. A zig test cannot set one for its own
// process without libc, so the `env` provider is exercised through the
// feature's `set_environ` seam with a map the test builds - the same seam a
// zig 0.16 application uses to hand in `init.environ_map` - and every other
// chain is a `memory` store or a scripted callable provider.
//
// This file lives in the test `feature/` container on purpose: build.zig
// names it only when the model activates `secrets`, alongside the feature
// source and the vendored library.
//
// ONE MODULE. A zig test module reaches only its own directory subtree, so
// this file cannot `@import("../../fh.zig")`; the small harness it needs is
// here, and the SDK is reached by module name.

const std = @import("std");
const sdk = @import("sdk");
const h = sdk.h;
const Value = sdk.Value;
const testing = std.testing;

const BASE = "http://secrets.test/api";

fn vnull() Value {
    return Value{ .null = {} };
}

// Every block runs only when the feature is in THIS SDK - build.zig lists
// this file only then, so this is belt and braces rather than a gate.
fn present() bool {
    const cfg = sdk.make_config();
    return h.getp(h.getp(cfg, "feature"), "secrets") == .object;
}

// ---- the counted transport ---------------------------------------------

/// One recorded request, SNAPSHOT at the moment it was handed to the
/// transport. A snapshot, not the fetchdef itself: the fetchdef's headers
/// map is rewritten IN PLACE by the exchange retry, so a recorder that kept
/// the live map would report every earlier call as carrying the LAST token.
const Call = struct {
    url: []const u8,
    auth: ?[]const u8,
    body: ?[]const u8,
};

/// A `system.fetch` that records every call it is handed, so "sent" is a
/// fact about the wire rather than about a mock somewhere up the chain. It
/// also plays the token endpoint for the exchange cases.
const Wire = struct {
    calls: std.ArrayList(Call) = .empty,
    /// One status per API call, the last repeating - so a case can say
    /// "401 then 200" without counting calls itself.
    apistatus: []const i64 = &.{200},
    /// The access tokens the token endpoint issues, in order.
    tokens: []const []const u8 = &.{ "ACCESS01", "ACCESS02", "ACCESS03" },
    tokenpath: []const u8 = "auth/token",
    tokenfield: []const u8 = "access_token",
    tokenstatus: []const i64 = &.{200},
    issued: usize = 0,
    apicalls: usize = 0,

    fn new() *Wire {
        const w = h.A().create(Wire) catch unreachable;
        w.* = .{};
        return w;
    }

    fn call(p: *anyopaque, _: std.mem.Allocator, arg: Value) anyerror!Value {
        const self: *Wire = @ptrCast(@alignCast(p));
        const url: []const u8 = if (arg == .array and 1 <= arg.array.data.items.len and arg.array.data.items[0] == .string)
            arg.array.data.items[0].string
        else
            "";
        const fetchdef: Value = if (arg == .array and 2 <= arg.array.data.items.len) arg.array.data.items[1] else vnull();
        const headers = h.getp(fetchdef, "headers");
        const auth: ?[]const u8 = if (h.get_str(headers, "authorization")) |a| (h.A().dupe(u8, a) catch a) else null;
        const body: ?[]const u8 = if (h.get_str(fetchdef, "body")) |b| (h.A().dupe(u8, b) catch b) else null;
        self.calls.append(h.A(), .{ .url = h.A().dupe(u8, url) catch url, .auth = auth, .body = body }) catch {};

        const suffix = std.fmt.allocPrint(h.A(), "/{s}", .{self.tokenpath}) catch "/auth/token";
        if (std.mem.endsWith(u8, url, suffix)) {
            const token = self.tokens[@min(self.issued, self.tokens.len - 1)];
            const status = self.tokenstatus[@min(self.issued, self.tokenstatus.len - 1)];
            self.issued += 1;
            return response(status, h.jo(&.{.{ self.tokenfield, h.vstr(token) }}));
        }

        const status = self.apistatus[@min(self.apicalls, self.apistatus.len - 1)];
        self.apicalls += 1;
        return response(status, h.jo(&.{ .{ "ok", h.vbool(status < 400) }, .{ "id", h.vstr("s01") } }));
    }

    fn fetch_fn(self: *Wire) Value {
        return h.callable(@ptrCast(self), call);
    }

    /// The API calls (everything that was not the token endpoint).
    fn api(self: *Wire) []Call {
        var out: std.ArrayList(Call) = .empty;
        const suffix = std.fmt.allocPrint(h.A(), "/{s}", .{self.tokenpath}) catch "/auth/token";
        for (self.calls.items) |c| {
            if (!std.mem.endsWith(u8, c.url, suffix)) out.append(h.A(), c) catch {};
        }
        return out.items;
    }

    fn token_calls(self: *Wire) usize {
        return self.calls.items.len - self.api().len;
    }
};

fn response(status: i64, data: Value) Value {
    return h.jo(&.{
        .{ "status", h.vnum(status) },
        .{ "statusText", h.vstr(if (status >= 400) "ERR" else "OK") },
        .{ "headers", h.omap() },
        .{ "json", h.json_thunk(data) },
        .{ "body", h.vstr("x") },
    });
}

// ---- a scripted provider ------------------------------------------------

/// A provider given as a callable (the feature's Value-shaped custom
/// provider seam): a string is a HIT, null a MISS, `{__err__}` an ERROR.
/// Scriptable per call, and it records every name it was asked.
const Scripted = struct {
    value: ?[]const u8 = null,
    err: ?[]const u8 = null,
    asked: usize = 0,
    names: std.ArrayList([]const u8) = .empty,

    fn new(value: ?[]const u8, err: ?[]const u8) *Scripted {
        const s = h.A().create(Scripted) catch unreachable;
        s.* = .{ .value = value, .err = err };
        return s;
    }

    fn call(p: *anyopaque, _: std.mem.Allocator, arg: Value) anyerror!Value {
        const self: *Scripted = @ptrCast(@alignCast(p));
        self.asked += 1;
        if (arg == .string) self.names.append(h.A(), arg.string) catch {};
        if (self.err) |m| return h.jo(&.{.{ "__err__", h.vstr(m) }});
        if (self.value) |v| return h.vstr(v);
        return vnull();
    }

    fn fn_val(self: *Scripted) Value {
        return h.callable(@ptrCast(self), call);
    }
};

// ---- clients --------------------------------------------------------------

/// Feature options: `{ active: true, providers: [...], ...extra }`.
fn secrets_opts(providers: Value, extra: Value) Value {
    const fo = h.jo(&.{
        .{ "active", h.vbool(true) },
        .{ "providers", providers },
    });
    if (extra == .object) {
        var it = extra.object.iterator();
        while (it.next()) |kv| h.setp(fo, kv.key_ptr.*, kv.value_ptr.*);
    }
    return fo;
}

/// A LIVE client whose `system.fetch` is the wire, with the secrets feature
/// handed in through the `extend` seam - installed exactly once whether or
/// not the generated Config already registered it, so these tests hold in
/// any generated tree.
fn live_client(w: *Wire, sdkopts: Value) *sdk.SDK {
    const opts: Value = if (sdkopts == .object) sdkopts else h.omap();
    h.setp(opts, "base", h.vstr(BASE));
    h.setp(opts, "system", h.jo(&.{.{ "fetch", w.fetch_fn() }}));
    return sdk.SDK.new_with(opts, &.{sdk.SecretsFeature.make()});
}

fn secrets_client(w: *Wire, sdkopts: Value, feature_opts: Value) *sdk.SDK {
    const opts: Value = if (sdkopts == .object) sdkopts else h.omap();
    h.setp(opts, "feature", h.jo(&.{.{ "secrets", feature_opts }}));
    return live_client(w, opts);
}

fn secrets_of(client: *sdk.SDK) ?*sdk.SecretsFeature {
    for (client.features.items) |f| {
        if (std.mem.eql(u8, f.name(), "secrets")) return @ptrCast(@alignCast(f.ptr));
    }
    return null;
}

fn count_named(client: *sdk.SDK, name: []const u8) usize {
    var n: usize = 0;
    for (client.features.items) |f| {
        if (std.mem.eql(u8, f.name(), name)) n += 1;
    }
    return n;
}

// The Authorization header carries the SPEC's credential prefix, which a
// TEMPLATE cannot know: an OpenAPI bearer scheme gives `Bearer <token>`, an
// apiKey scheme the raw token. So assert on the CREDENTIAL and let the
// prefix be whatever this SDK's API declares.
fn credential_is(auth: ?[]const u8, token: []const u8) !void {
    const got = auth orelse "";
    const suffix = std.fmt.allocPrint(h.A(), " {s}", .{token}) catch token;
    if (!(std.mem.eql(u8, got, token) or std.mem.endsWith(u8, got, suffix))) {
        std.debug.print("expected the authorization header to carry {s}, got: {s}\n", .{ token, got });
        return error.TestUnexpectedResult;
    }
}

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

// ---- the entity driver ----------------------------------------------------

const Drive = struct {
    ran: bool,
    ok: bool,
    msg: []const u8,
};

/// Drive one REAL generated entity op through the pipeline. The client's
/// entity accessors are `pub fn <name>(self: *SDK, entopts: Value) *Ent`;
/// found by comptime reflection (the zig spelling of go's reflect-based
/// driver), and the first entity whose model op map declares `load` or
/// `list` is driven. `ran == false` means this SDK has no such entity.
fn drive_entity(client: *sdk.SDK) Drive {
    const cfg = sdk.make_config();
    const info = @typeInfo(sdk.SDK).@"struct";

    inline for (info.decls) |d| {
        const F = @TypeOf(@field(sdk.SDK, d.name));
        const fi = @typeInfo(F);
        if (fi == .@"fn") {
            const params = fi.@"fn".params;
            if (params.len == 2 and params[0].type == *sdk.SDK and params[1].type == Value) {
                if (fi.@"fn".return_type) |R| {
                    if (@typeInfo(R) == .pointer and @typeInfo(@typeInfo(R).pointer.child) == .@"struct" and
                        @hasDecl(@typeInfo(R).pointer.child, "load"))
                    {
                        const ent = @field(sdk.SDK, d.name)(client, vnull());
                        const ops = h.getpath(&.{ "entity", ent.name, "op" }, cfg);
                        if (h.getp(ops, "load") == .object) {
                            const res = ent.load(h.jo(&.{.{ "id", h.vstr("s01") }}), vnull());
                            return switch (res) {
                                .err => |e| .{ .ran = true, .ok = false, .msg = e.msg },
                                .ok => .{ .ran = true, .ok = true, .msg = "" },
                            };
                        } else if (h.getp(ops, "list") == .object) {
                            const res = ent.list(h.omap(), vnull());
                            return switch (res) {
                                .err => |e| .{ .ran = true, .ok = false, .msg = e.msg },
                                .ok => .{ .ran = true, .ok = true, .msg = "" },
                            };
                        }
                    }
                }
            }
        }
    }

    return .{ .ran = false, .ok = false, .msg = "" };
}

fn direct_probe(client: *sdk.SDK) Value {
    return client.direct(h.jo(&.{.{ "path", h.vstr("/probe") }}));
}

// ---- inactive --------------------------------------------------------------

test "secrets inactive: apikey option behaves exactly as before" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = live_client(w, h.jo(&.{.{ "apikey", h.vstr("OPTKEY01") }}));
    // No feature options, no install: `extend` hands the feature in, but an
    // inactive feature installs nothing on the transport.
    const res = direct_probe(client);
    try testing.expect(h.get_bool(res, "ok") orelse false);
    try testing.expect(w.api().len == 1);
    try credential_is(w.api()[0].auth, "OPTKEY01");
}

test "secrets inactive: no apikey means no authorization header" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = live_client(w, h.omap());
    _ = direct_probe(client);
    try testing.expect(w.api().len == 1);
    try testing.expect(w.api()[0].auth == null);
}

// ---- the chain ---------------------------------------------------------------

test "secrets active: apikey option still wins over the chain" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const chain = Scripted.new("CHAINKEY01", null);
    const client = secrets_client(w, h.jo(&.{.{ "apikey", h.vstr("OPTKEY01") }}), secrets_opts(h.ja(&.{chain.fn_val()}), vnull()));

    const drove = drive_entity(client);
    if (!drove.ran) return error.SkipZigTest;
    try testing.expect(drove.ok);
    try testing.expect(w.api().len == 1);
    try credential_is(w.api()[0].auth, "OPTKEY01");

    // The explicit option is a real store, not a special case: a directed
    // read names it like any other.
    const sf = secrets_of(client) orelse return error.TestUnexpectedResult;
    switch (sf.getfrom("options", "apikey")) {
        .ok => |v| try testing.expectEqualStrings("OPTKEY01", v),
        .err => |m| {
            std.debug.print("directed read failed: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "secrets active: an omitted apikey defers to the chain at the transport seam" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const chain = Scripted.new("CHAINKEY02", null);
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{chain.fn_val()}), vnull()));
    const sf = secrets_of(client) orelse return error.TestUnexpectedResult;

    // Before any op, nothing has been resolved: resolution happens AT THE
    // TRANSPORT, not at construction.
    try testing.expectEqualStrings("", sf.credential());
    try testing.expect(chain.asked == 0);

    const drove = drive_entity(client);
    if (!drove.ran) return error.SkipZigTest;
    try testing.expect(drove.ok);
    try credential_is(w.api()[0].auth, "CHAINKEY02");
    try testing.expectEqualStrings("CHAINKEY02", sf.credential());

    // The options map is never written: the credential lives in feature
    // state and is injected on the wire.
    try testing.expectEqualStrings("", h.get_str(client.options_map(), "apikey") orelse "");
}

test "secrets active: the env provider reads the environment handed in" {
    if (!present()) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(h.A());
    try env.put("PROJECTENV_TEST_SECRETS_APIKEY", "ENVKEY01");
    sdk.SecretsFeature.set_environ(&env);
    defer sdk.SecretsFeature.set_environ(null);

    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{
        h.jo(&.{ .{ "kind", h.vstr("env") }, .{ "prefix", h.vstr("PROJECTENV_TEST_SECRETS_") } }),
    }), vnull()));
    _ = direct_probe(client);
    try testing.expect(w.api().len == 1);
    try credential_is(w.api()[0].auth, "ENVKEY01");
}

test "secrets active: a memory spec map is decoded through sekreto's own specof" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{
        h.jo(&.{
            .{ "kind", h.vstr("memory") },
            .{ "name", h.vstr("literal") },
            .{ "values", h.jo(&.{.{ "APIKEY", h.vstr("MEMKEY01") }}) },
        }),
    }), vnull()));
    _ = direct_probe(client);
    try credential_is(w.api()[0].auth, "MEMKEY01");
    const sf = secrets_of(client) orelse return error.TestUnexpectedResult;
    switch (sf.getfrom("literal", "apikey")) {
        .ok => |v| try testing.expectEqualStrings("MEMKEY01", v),
        .err => return error.TestUnexpectedResult,
    }
}

test "secrets active: a miss everywhere leaves the header off" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const chain = Scripted.new(null, null);
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{chain.fn_val()}), vnull()));
    const drove = drive_entity(client);
    if (!drove.ran) return error.SkipZigTest;
    try testing.expect(drove.ok);
    try testing.expect(chain.asked == 1);
    // A MISS falls through: the request still goes out, unauthenticated.
    try testing.expect(w.api().len == 1);
    try testing.expect(w.api()[0].auth == null);
}

test "secrets active: a provider ERROR fails the entity op and nothing reaches the wire" {
    if (!present()) return error.SkipZigTest;

    // CONTROL FIRST, so the zero below is known to be observable at all.
    const control = Wire.new();
    const good = secrets_client(control, h.omap(), secrets_opts(h.ja(&.{Scripted.new("GOODKEY01", null).fn_val()}), vnull()));
    const cdrove = drive_entity(good);
    if (!cdrove.ran) return error.SkipZigTest;
    try testing.expect(cdrove.ok);
    try testing.expect(control.api().len == 1);
    try credential_is(control.api()[0].auth, "GOODKEY01");

    // THE RULE.
    const w = Wire.new();
    const broken = Scripted.new(null, "vault unreachable");
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{broken.fn_val()}), vnull()));
    const drove = drive_entity(client);
    try testing.expect(drove.ran);
    try testing.expect(!drove.ok);
    try testing.expect(broken.asked == 1);
    // The PROVIDER'S OWN message, and ZERO requests on the wire.
    try testing.expect(contains(drove.msg, "vault unreachable"));
    try testing.expect(w.api().len == 0);
}

test "secrets active: a provider ERROR fails direct() rather than sending" {
    if (!present()) return error.SkipZigTest;

    const control = Wire.new();
    const good = secrets_client(control, h.omap(), secrets_opts(h.ja(&.{Scripted.new("GOODKEY02", null).fn_val()}), vnull()));
    const cres = direct_probe(good);
    try testing.expect(h.get_bool(cres, "ok") orelse false);
    try testing.expect(control.api().len == 1);
    try credential_is(control.api()[0].auth, "GOODKEY02");

    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{Scripted.new(null, "vault unreachable").fn_val()}), vnull()));
    const res = direct_probe(client);
    try testing.expect(res == .object);
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    try testing.expect(contains(h.get_str(res, "err") orelse "", "vault unreachable"));
    try testing.expect(w.api().len == 0);
}

test "secrets active: a provider ERROR fails graphql() rather than sending" {
    if (!present()) return error.SkipZigTest;

    const control = Wire.new();
    const good = secrets_client(control, h.omap(), secrets_opts(h.ja(&.{Scripted.new("GOODKEY03", null).fn_val()}), vnull()));
    const cres = good.graphql("{ ok }", vnull(), vnull());
    try testing.expect(h.get_bool(cres, "ok") orelse false);
    try testing.expect(control.api().len == 1);
    try credential_is(control.api()[0].auth, "GOODKEY03");

    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{Scripted.new(null, "vault unreachable").fn_val()}), vnull()));
    const res = client.graphql("{ ok }", vnull(), vnull());
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    try testing.expect(contains(h.get_str(res, "err") orelse "", "vault unreachable"));
    try testing.expect(w.api().len == 0);
}

// FAIL CLOSED ON A CONSTRUCTION FAILURE. The chain a project configures can
// be wrong before a single lookup happens, and init cannot fail the client
// construction - so it HOLDS the error and the transport gate refuses to
// send. The entry pinned here is a bare kind name where a spec belongs: a
// switch without a fail-closed arm silently DROPS it, the chain gets SHORTER
// rather than broken, and every request goes out unauthenticated.
test "secrets active: a malformed providers entry fails closed, never dropped" {
    if (!present()) return error.SkipZigTest;
    const notaprovider = "not a provider or a provider spec";

    // CONTROL FIRST.
    const control = Wire.new();
    const good = secrets_client(control, h.omap(), secrets_opts(h.ja(&.{Scripted.new("INITKEY01", null).fn_val()}), vnull()));
    const cres = direct_probe(good);
    try testing.expect(h.get_bool(cres, "ok") orelse false);
    try testing.expect(control.api().len == 1);
    try credential_is(control.api()[0].auth, "INITKEY01");

    // THE RULE: a kind NAME where a provider or spec belongs.
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{h.vstr("hashicorp")}), vnull()));

    // The feature must still be INSTALLED: a construction failure that
    // silently uninstalled it would be the same fail-open by another route.
    const sf = secrets_of(client) orelse return error.TestUnexpectedResult;
    try testing.expect(contains(sf.init_error() orelse "", notaprovider));

    // direct runs no feature hook at all, so the ONLY thing that can refuse
    // it is the transport gate - with sekreto's own message.
    const res = direct_probe(client);
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    try testing.expect(contains(h.get_str(res, "err") orelse "", notaprovider));
    try testing.expect(w.api().len == 0);

    // And the entity pipeline.
    const drove = drive_entity(client);
    if (drove.ran) {
        try testing.expect(!drove.ok);
        try testing.expect(contains(drove.msg, notaprovider));
    }
    try testing.expect(w.api().len == 0);
}

test "secrets active: an unknown provider kind is refused by name, fail-closed" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{
        h.jo(&.{.{ "kind", h.vstr("nosuchkind") }}),
    }), vnull()));
    const res = direct_probe(client);
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    try testing.expect(contains(h.get_str(res, "err") orelse "", "sekreto: unknown provider kind: nosuchkind"));
    try testing.expect(w.api().len == 0);
}

// A provider failure closes the gate; a later resolution that SUCCEEDS
// reopens it and the operation goes out with the FRESH credential - a failed
// resolution is never cached.
test "secrets active: the gate recovers after a transient provider failure" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const flaky = Scripted.new(null, "vault unreachable");
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{flaky.fn_val()}), vnull()));

    const first = direct_probe(client);
    try testing.expect(!(h.get_bool(first, "ok") orelse true));
    try testing.expect(w.api().len == 0);

    flaky.err = null;
    flaky.value = "FRESH01";

    const second = direct_probe(client);
    try testing.expect(h.get_bool(second, "ok") orelse false);
    try testing.expect(w.api().len == 1);
    try credential_is(w.api()[0].auth, "FRESH01");
}

test "secrets active: an uncached miss retracts a resolved credential" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const revocable = Scripted.new("REVOCABLE01", null);
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{revocable.fn_val()}), h.jo(&.{.{ "cache", h.vbool(false) }})));

    _ = direct_probe(client);
    try credential_is(w.api()[0].auth, "REVOCABLE01");

    revocable.value = null;
    _ = direct_probe(client);
    try testing.expect(w.api().len == 2);
    // After the chain reports a miss, the retracted credential must not go
    // out.
    try testing.expect(w.api()[1].auth == null);
}

test "secrets active: cache true asks the chain once, cache false every request" {
    if (!present()) return error.SkipZigTest;
    const cached = Scripted.new("K", null);
    const cw = Wire.new();
    const cclient = secrets_client(cw, h.omap(), secrets_opts(h.ja(&.{cached.fn_val()}), vnull()));
    _ = direct_probe(cclient);
    _ = direct_probe(cclient);
    try testing.expect(cw.api().len == 2);
    try testing.expect(cached.asked == 1);

    const fresh = Scripted.new("K", null);
    const fw = Wire.new();
    const fclient = secrets_client(fw, h.omap(), secrets_opts(h.ja(&.{fresh.fn_val()}), h.jo(&.{.{ "cache", h.vbool(false) }})));
    _ = direct_probe(fclient);
    _ = direct_probe(fclient);
    try testing.expect(fw.api().len == 2);
    try testing.expect(fresh.asked == 2);
}

// `auth: null` - the documented way to disable auth outright, which
// prepare_auth honours before it ever reads the apikey. Pinned with an
// explicit apikey AND a resolving chain: nothing may reach the wire.
test "secrets active: auth null suppresses the credential, chain or no chain" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const chain = Scripted.new("CHAINKEY03", null);
    const client = secrets_client(w, h.jo(&.{
        .{ "apikey", h.vstr("OPTKEY01") },
        .{ "auth", h.vnull() },
    }), secrets_opts(h.ja(&.{chain.fn_val()}), vnull()));

    const res = direct_probe(client);
    try testing.expect(h.get_bool(res, "ok") orelse false);
    try testing.expect(w.api().len == 1);
    try testing.expect(w.api()[0].auth == null);

    // And options.auth survives validate as a PRESENT null, not a default.
    const opts = client.options_map();
    try testing.expect(opts == .object);
    const raw = opts.object.get("auth") orelse return error.TestUnexpectedResult;
    try testing.expect(raw == .null);
}

test "secrets active: the secret name is configurable" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const chain = Scripted.new("TOKEN01", null);
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{chain.fn_val()}), h.jo(&.{.{ "name", h.vstr("api.token") }})));
    _ = direct_probe(client);
    try credential_is(w.api()[0].auth, "TOKEN01");
    try testing.expect(chain.names.items.len == 1);
    try testing.expectEqualStrings("api.token", chain.names.items[0]);
}

test "secrets active: sekreto is live for arbitrary secrets and redaction" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{
        h.jo(&.{
            .{ "kind", h.vstr("memory") },
            .{ "values", h.jo(&.{ .{ "APIKEY", h.vstr("MEMKEY02") }, .{ "DB_PASS", h.vstr("hunter22") } }) },
        }),
    }), vnull()));
    const sf = secrets_of(client) orelse return error.TestUnexpectedResult;

    switch (sf.get("db.pass")) {
        .ok => |v| try testing.expectEqualStrings("hunter22", v),
        .err => return error.TestUnexpectedResult,
    }
    switch (sf.get("nope")) {
        .ok => return error.TestUnexpectedResult,
        .err => |m| try testing.expect(contains(m, "sekreto: unknown secret: nope")),
    }
    // Every value ever resolved is redactable.
    const redacted = sf.redact("pass=hunter22 key=MEMKEY02");
    try testing.expect(!contains(redacted, "hunter22"));
    try testing.expect(contains(redacted, "[redacted]"));
}

// The plugin VOCABULARY: a kind the model selected (Config_zig FeaturePlugins
// -> feature/secrets/plugins.zig) builds; one it did not is refused by name
// with sekreto's own "pass it in the plugins option" message. This test
// selects `hashicorp` (the `vault` group) against a closed loopback port: a
// selected kind fails CLOSED with a reach error, an unselected one fails
// closed at construction. Either way nothing reaches the wire.
test "secrets active: a selected plugin kind is in the SDK vocabulary" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{
        h.jo(&.{
            .{ "kind", h.vstr("hashicorp") },
            .{ "addr", h.vstr("http://127.0.0.1:9") },
            .{ "token", h.vstr("t") },
        }),
    }), vnull()));
    const sf = secrets_of(client) orelse return error.TestUnexpectedResult;

    if (sf.init_error()) |message| {
        // The vault group was not generated into this SDK: the kind is
        // refused BY NAME, and the suite says so rather than passing.
        try testing.expect(contains(message, "sekreto: unknown provider kind: hashicorp"));
        try testing.expect(contains(message, "pass it in the plugins option"));
        return error.SkipZigTest;
    }

    const res = direct_probe(client);
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    try testing.expect(contains(h.get_str(res, "err") orelse "", "sekreto: cannot reach http://127.0.0.1:9/"));
    try testing.expect(w.api().len == 0);
}

test "secrets: the extend seam installs a directly constructed feature exactly once" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{Scripted.new("K", null).fn_val()}), vnull()));
    try testing.expect(count_named(client, "secrets") == 1);
    // Whether Config registered it or extend supplied it, one wrapper: one
    // request reaches the wire per operation.
    _ = direct_probe(client);
    try testing.expect(w.api().len == 1);
}

// ---- the exchange ----------------------------------------------------------

fn exchange_opts(providers: Value, extra: Value) Value {
    const xo = h.jo(&.{.{ "active", h.vbool(true) }});
    if (extra == .object) {
        var it = extra.object.iterator();
        while (it.next()) |kv| h.setp(xo, kv.key_ptr.*, kv.value_ptr.*);
    }
    return secrets_opts(providers, h.jo(&.{
        .{ "name", h.vstr("refresh_token") },
        .{ "exchange", xo },
    }));
}

test "secrets exchange: the refresh token buys an access token, and the request carries it" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()));
    const res = direct_probe(client);
    try testing.expect(h.get_bool(res, "ok") orelse false);

    try testing.expect(w.token_calls() == 1);
    try testing.expect(contains(w.calls.items[0].body orelse "", "\"refresh_token\":\"REFRESH01\""));
    try testing.expect(std.mem.endsWith(u8, w.calls.items[0].url, "/api/auth/token"));
    try testing.expect(w.api().len == 1);
    try credential_is(w.api()[0].auth, "ACCESS01");
}

test "secrets exchange: one purchase serves many requests" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()));
    _ = direct_probe(client);
    _ = direct_probe(client);
    _ = direct_probe(client);
    try testing.expect(w.token_calls() == 1);
    try testing.expect(w.api().len == 3);
    try credential_is(w.api()[2].auth, "ACCESS01");
}

test "secrets exchange: a 401 buys another token and retries the SAME request" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    w.apistatus = &.{ 401, 200 };
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()));
    const res = direct_probe(client);
    try testing.expect(h.get_bool(res, "ok") orelse false);
    try testing.expect(w.token_calls() == 2);
    try testing.expect(w.api().len == 2);
    try credential_is(w.api()[0].auth, "ACCESS01");
    try credential_is(w.api()[1].auth, "ACCESS02");
    try testing.expectEqualStrings(w.api()[0].url, w.api()[1].url);
}

test "secrets exchange: the retry happens once, not in a loop" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    w.apistatus = &.{401};
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()));
    const res = direct_probe(client);
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    try testing.expect(h.to_int(h.getp(res, "status")) == 401);
    try testing.expect(w.api().len == 2);
    try testing.expect(w.token_calls() == 2);
}

test "secrets exchange: a status outside exchange.statuses is not an expiry" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    w.apistatus = &.{500};
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()));
    _ = direct_probe(client);
    try testing.expect(w.api().len == 1);
    try testing.expect(w.token_calls() == 1);
}

test "secrets exchange: statuses and field names are configurable" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    w.apistatus = &.{ 403, 200 };
    w.tokenpath = "oauth/refresh";
    w.tokenfield = "token";
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), h.jo(&.{
        .{ "statuses", h.ja(&.{h.vnum(403)}) },
        .{ "path", h.vstr("oauth/refresh") },
        .{ "request", h.vstr("grant") },
        .{ "response", h.vstr("token") },
    })));
    const res = direct_probe(client);
    try testing.expect(h.get_bool(res, "ok") orelse false);
    try testing.expect(w.token_calls() == 2);
    try testing.expect(contains(w.calls.items[0].body orelse "", "\"grant\":\"REFRESH01\""));
    try credential_is(w.api()[1].auth, "ACCESS02");
}

test "secrets exchange: an explicit apikey is spent before anything is bought" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    w.apistatus = &.{ 401, 200 };
    const client = secrets_client(w, h.jo(&.{.{ "apikey", h.vstr("HELD01") }}), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()));
    const res = direct_probe(client);
    try testing.expect(h.get_bool(res, "ok") orelse false);
    // The held token went out first, with NO purchase; its expiry bought one.
    try credential_is(w.api()[0].auth, "HELD01");
    try credential_is(w.api()[1].auth, "ACCESS01");
    try testing.expect(w.token_calls() == 1);
}

test "secrets exchange: an explicit exchange.refresh wins over the chain" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new("CHAINREFRESH", null).fn_val()}), h.jo(&.{.{ "refresh", h.vstr("GIVENREFRESH") }})));
    _ = direct_probe(client);
    try testing.expect(contains(w.calls.items[0].body orelse "", "GIVENREFRESH"));
}

test "secrets exchange: no refresh token anywhere is an error, not an unauthenticated call" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new(null, null).fn_val()}), vnull()));
    const res = direct_probe(client);
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    try testing.expect(contains(h.get_str(res, "err") orelse "", "secrets: no refresh token"));
    try testing.expect(w.calls.items.len == 0);
}

test "secrets exchange: a failing token endpoint surfaces the API refusal, not a spin" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    w.apistatus = &.{401};
    w.tokenstatus = &.{ 200, 500 };
    const client = secrets_client(w, h.omap(), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()));
    const res = direct_probe(client);
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    try testing.expect(h.to_int(h.getp(res, "status")) == 401);
    try testing.expect(h.get_str(res, "err") == null);
    try testing.expect(w.api().len == 1);
    try testing.expect(w.token_calls() == 2);
}

test "secrets exchange: auth null suppresses the credential, refusal or not" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    w.apistatus = &.{401};
    const client = secrets_client(w, h.jo(&.{.{ "auth", h.vnull() }}), exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()));
    _ = direct_probe(client);
    try testing.expect(w.api().len == 1);
    try testing.expect(w.api()[0].auth == null);
}

test "secrets exchange: exchange off leaves the feature exactly as it was" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const client = secrets_client(w, h.omap(), secrets_opts(h.ja(&.{Scripted.new("PLAINKEY01", null).fn_val()}), h.jo(&.{
        .{ "exchange", h.jo(&.{.{ "active", h.vbool(false) }}) },
    })));
    _ = direct_probe(client);
    try testing.expect(w.token_calls() == 0);
    try credential_is(w.api()[0].auth, "PLAINKEY01");
}

test "secrets exchange: test mode buys nothing and needs no token endpoint" {
    if (!present()) return error.SkipZigTest;
    const w = Wire.new();
    const opts = h.jo(&.{
        .{ "system", h.jo(&.{.{ "fetch", w.fetch_fn() }}) },
        .{ "feature", h.jo(&.{.{ "secrets", exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()) }}) },
    });
    const client = sdk.test_sdk(vnull(), opts);
    const sf = secrets_of(client) orelse return error.TestUnexpectedResult;
    _ = direct_probe(client);
    try testing.expectEqualStrings("test-access_token", sf.credential());
    try testing.expect(w.calls.items.len == 0);
}

// THE BUNDLED TRANSPORT OF LAST RESORT. With no `system.fetch`, the exchange
// uses the vendored sekreto plugins' own HTTP client. A closed loopback port
// answers with sekreto's own reach error, which proves the path is wired
// and that its failure is fail-closed - no request reaches the API.
test "secrets exchange: without system.fetch the bundled HTTP transport buys the token" {
    if (!present()) return error.SkipZigTest;
    const opts = h.jo(&.{
        .{ "base", h.vstr("http://127.0.0.1:9/api") },
        .{ "feature", h.jo(&.{.{ "secrets", exchange_opts(h.ja(&.{Scripted.new("REFRESH01", null).fn_val()}), vnull()) }}) },
    });
    const client = sdk.SDK.new_with(opts, &.{sdk.SecretsFeature.make()});
    const res = direct_probe(client);
    try testing.expect(!(h.get_bool(res, "ok") orelse true));
    const msg = h.get_str(res, "err") orelse "";
    try testing.expect(contains(msg, "sekreto: cannot reach http://127.0.0.1:9/api/auth/token"));
}
