// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/hashicorp.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! HashiCorp Vault - a sekreto plugin.
//!
//! One definition, `hashicorp`, built by `sekreto.providerplugin`: its
//! `define` reads the spec off the instance and builds the provider
//! below. Needs HTTPS (and a file read, for a kubernetes JWT), which is
//! why it is a plugin and not built in: a chain that never names it
//! never links it.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// HashiCorp Vault.
///
/// KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
/// takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
/// `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
/// here" - a miss - so a vault can sit in a chain with fallbacks.
///
/// A Vault Enterprise namespace rides the X-Vault-Namespace header, on
/// logins as well as reads.
///
/// Instead of being handed a token, the provider can log in: Kubernetes
/// auth (the pod's service-account JWT, from its conventional path) or
/// AppRole. A failed login is an error, never a miss - it means this store
/// could not answer at all.
pub const HashicorpProvider = struct {
    alloc: Allocator,
    config: sekreto.Config,
    addr: []const u8,
    token: []const u8,
    mount: []const u8,
    kv: i64,
    vaultnamespace: []const u8,
    auth: ?sekreto.Auth,
    // The working token: a configured token is kept forever, a logged-in
    // token is renewed shortly before its lease runs out.
    livetoken: ?[]const u8,
    renewat: i64,

    fn baseheaders(self: *HashicorpProvider, alloc: Allocator) Allocator.Error!std.ArrayList(httpjson.Header) {
        var headers: std.ArrayList(httpjson.Header) = .empty;
        if (0 != self.vaultnamespace.len) {
            try headers.append(alloc, .{ .name = "X-Vault-Namespace", .value = self.vaultnamespace });
        }
        return headers;
    }

    fn login(self: *HashicorpProvider, alloc: Allocator) Allocator.Error!Answer([]const u8) {
        const auth = self.auth orelse {
            return .{ .err = try sekreto.fail(alloc, "sekreto: hashicorp: no token and no auth method", .{}) };
        };

        const mount = if (0 != auth.mount.len) auth.mount else auth.method;
        const url = try std.fmt.allocPrint(
            alloc,
            "{s}/v1/auth/{s}/login",
            .{ httpjson.trimslash(self.addr), mount },
        );

        var body: []const u8 = undefined;

        if (std.mem.eql(u8, "kubernetes", auth.method)) {
            const jwt = auth.jwt orelse blk: {
                const file = if (0 != auth.jwtfile.len)
                    auth.jwtfile
                else
                    "/var/run/secrets/kubernetes.io/serviceaccount/token";

                const text = std.Io.Dir.cwd().readFileAlloc(
                    self.config.io,
                    file,
                    alloc,
                    .unlimited,
                ) catch {
                    return .{ .err = try sekreto.fail(
                        alloc,
                        "sekreto: hashicorp: cannot read jwt file {s}",
                        .{file},
                    ) };
                };

                break :blk std.mem.trim(u8, text, " \t\r\n");
            };

            body = try httpjson.jsonobject(alloc, &.{
                .{ .key = "role", .value = auth.role },
                .{ .key = "jwt", .value = jwt },
            });
        } else if (std.mem.eql(u8, "approle", auth.method)) {
            body = try httpjson.jsonobject(alloc, &.{
                .{ .key = "role_id", .value = auth.roleid },
                .{ .key = "secret_id", .value = auth.secretid },
            });
        } else {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: hashicorp: unknown auth method: {s}",
                .{auth.method},
            ) };
        }

        var headers = try self.baseheaders(alloc);
        try headers.append(alloc, .{ .name = "content-type", .value = "application/json" });

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .POST, url, headers.items, body)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const clienttoken = httpjson.jstr(httpjson.jget(httpjson.jget(res.body, "auth"), "client_token"));

        if (200 != res.status or null == clienttoken) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: hashicorp login failed: {d}: {s}",
                .{ res.status, url },
            ) };
        }

        self.renewat = httpjson.renewafter(
            self.config.io,
            httpjson.jnum(httpjson.jget(httpjson.jget(res.body, "auth"), "lease_duration")),
        );

        return .{ .ok = clienttoken.? };
    }

    pub fn lookup(self: *HashicorpProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        switch (try sekreto.checkaddr(alloc, self.addr)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        if (null == self.livetoken or httpjson.nowms(self.config.io) >= self.renewat) {
            const fresh = switch (try self.login(alloc)) {
                .err => |message| return .{ .err = message },
                .ok => |got| got,
            };
            try self.settoken(fresh);
        }

        const ref = switch (try sekreto.vaultref(alloc, name)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const url = if (1 == self.kv)
            try std.fmt.allocPrint(alloc, "{s}/v1/{s}/{s}", .{ httpjson.trimslash(self.addr), self.mount, ref.path })
        else
            try std.fmt.allocPrint(alloc, "{s}/v1/{s}/data/{s}", .{ httpjson.trimslash(self.addr), self.mount, ref.path });

        var headers = try self.baseheaders(alloc);
        try headers.append(alloc, .{ .name = "X-Vault-Token", .value = self.livetoken.? });

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, url, headers.items, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        if (404 == res.status) {
            return .{ .ok = null };
        }

        if (200 != res.status) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: hashicorp error: {d}: {s}",
                .{ res.status, url },
            ) };
        }

        const data = if (1 == self.kv)
            httpjson.jget(res.body, "data")
        else
            httpjson.jget(httpjson.jget(res.body, "data"), "data");

        return .{ .ok = httpjson.jstr(httpjson.jget(data, ref.field)) };
    }

    // The live token outlives one lookup, so it cannot live in the lookup's
    // scratch arena; the previous one is freed as it is replaced.
    fn settoken(self: *HashicorpProvider, token: []const u8) Allocator.Error!void {
        if (self.livetoken) |old| {
            self.alloc.free(old);
        }
        self.livetoken = try self.alloc.dupe(u8, token);
    }

    pub fn describe(self: *HashicorpProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "hashicorp:{s}/{s}", .{ self.addr, self.mount });
    }

    pub fn deinit(self: *HashicorpProvider, alloc: Allocator) void {
        if (self.livetoken) |token| {
            alloc.free(token);
        }
    }
};

fn make(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    const kv: i64 = if (0 == spec.kv) 2 else spec.kv;

    // A version typo like kv: 3 must not quietly behave as v2 and turn
    // its 404s into misses; there is nothing safe to assume it meant.
    if (1 != kv and 2 != kv) {
        return .{ .err = try sekreto.fail(
            alloc,
            "sekreto: hashicorp: unsupported kv version: {d}",
            .{kv},
        ) };
    }

    return .{
        .ok = try sekreto.provide(alloc, HashicorpProvider, .{
            .alloc = alloc,
            .config = config,
            .addr = spec.addr,
            .token = spec.token,
            .mount = if (0 != spec.mount.len) spec.mount else "secret",
            .kv = kv,
            .vaultnamespace = spec.vaultnamespace,
            .auth = spec.auth,
            // A configured token is the live token, and is kept forever.
            .livetoken = if (0 == spec.token.len) null else try alloc.dupe(u8, spec.token),
            .renewat = httpjson.NEVER,
        }),
    };
}

/// The `hashicorp` kind.
pub const hashicorp: sekreto.Definition = sekreto.providerplugin("hashicorp", make);
