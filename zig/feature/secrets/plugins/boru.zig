// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/boru.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! A boru vault (https://github.com/boru-lang/boru) - a sekreto plugin.
//!
//! Spawns the boru CLI, or speaks its wire protocol over HTTPS; either
//! way it reaches outside the process, which is why it is a plugin.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// A boru vault (https://github.com/boru-lang/boru).
///
/// Two ways in, both boru's own.
///
/// With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
/// secret on stdout and nothing else. The passphrase is read by boru itself
/// from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config and
/// never puts it on a command line, where it would show up in the process
/// table.
///
/// With an `addr`, boru's wire protocol: `boru vault serve` publishes a
/// read-only, HashiCorp-shaped provision API, authenticated by a capability
/// token from `boru vault grant`. A sekreto name is already a valid boru
/// alias, and boru aliases keep their dots, so `api.token` is the single
/// path segment `api.token` - not the `api`/`token` split a HashiCorp KV
/// gets. The value is the `value` field. A 404 is a miss; anything else the
/// server refuses (a revoked capability, a sealed vault) is an error.
///
/// boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
/// credential *broker*, built precisely so the caller never receives the
/// credential. `vault serve` is the provision endpoint, built to hand the
/// value back - that is the one sekreto uses.
pub const BoruProvider = struct {
    alloc: Allocator,
    config: sekreto.Config,
    command: []const u8,
    namespace: []const u8,
    home: []const u8,
    addr: []const u8,
    token: []const u8,
    mount: []const u8,

    pub fn lookup(self: *BoruProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        switch (try sekreto.checkname(alloc, name)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        if (0 != self.addr.len) {
            return self.lookupwire(alloc, name);
        }

        return self.lookupcli(alloc, name);
    }

    fn lookupwire(self: *BoruProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const addr = httpjson.trimslash(self.addr);

        switch (try sekreto.checkaddr(alloc, addr)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        const alias = if (0 != self.namespace.len)
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.namespace, name })
        else
            name;

        const url = try std.fmt.allocPrint(alloc, "{s}/v1/{s}/data/{s}", .{ addr, self.mount, alias });

        const headers = [_]httpjson.Header{.{ .name = "X-Vault-Token", .value = self.token }};

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, url, &headers, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        if (404 == res.status) {
            return .{ .ok = null };
        }

        if (200 != res.status) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: boru serve error: {d}: {s}",
                .{ res.status, url },
            ) };
        }

        const data = httpjson.jget(httpjson.jget(res.body, "data"), "data");
        return .{ .ok = httpjson.jstr(httpjson.jget(data, "value")) };
    }

    fn lookupcli(self: *BoruProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const alias = if (0 != self.namespace.len)
            try std.fmt.allocPrint(alloc, "{s}:{s}", .{ self.namespace, name })
        else
            name;

        // BORU_HOME is added to a copy of the environment, never to the
        // command line: the passphrase boru reads from the environment must
        // not end up in the process table beside it.
        var environ = try self.config.env.clone(alloc);
        defer environ.deinit();

        if (0 != self.home.len) {
            try environ.put("BORU_HOME", self.home);
        }

        const run = std.process.run(alloc, self.config.io, .{
            .argv = &.{ self.command, "vault", "get", "--reveal", alias },
            .environ_map = &environ,
        }) catch |err| {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: cannot run {s}: {s}",
                .{ self.command, @errorName(err) },
            ) };
        };

        const exited = switch (run.term) {
            .exited => |code| code,
            else => 1,
        };

        if (0 == exited) {
            // boru prints the value and one newline, and nothing else.
            var value: []const u8 = run.stdout;
            if (0 != value.len and '\n' == value[value.len - 1]) {
                value = value[0 .. value.len - 1];
            }
            return .{ .ok = value };
        }

        const why = std.mem.trim(u8, run.stderr, " \t\r\n");

        // "no alias named" is boru saying it does not hold this secret,
        // which is a miss: the chain carries on to the next provider. A
        // locked vault or a wrong passphrase is not a miss - treating it as
        // one would fall through to a weaker store without saying so.
        if (null != std.mem.indexOf(u8, why, "no alias named")) {
            return .{ .ok = null };
        }

        if (0 != why.len) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: boru vault error: {s}", .{why}) };
        }

        return .{ .err = try sekreto.fail(alloc, "sekreto: boru vault error: exit {d}", .{exited}) };
    }

    pub fn describe(self: *BoruProvider, alloc: Allocator) Allocator.Error![]const u8 {
        if (0 != self.addr.len) {
            return std.fmt.allocPrint(alloc, "boru:{s}", .{httpjson.trimslash(self.addr)});
        }
        if (0 != self.namespace.len) {
            return std.fmt.allocPrint(alloc, "boru:{s}", .{self.namespace});
        }
        return alloc.dupe(u8, "boru");
    }

    pub fn deinit(_: *BoruProvider, _: Allocator) void {}
};

fn make(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, BoruProvider, .{
        .alloc = alloc,
        .config = config,
        .command = if (0 != spec.command.len) spec.command else "boru",
        .namespace = spec.namespace,
        .home = spec.home,
        .addr = spec.addr,
        .token = spec.token,
        .mount = if (0 != spec.mount.len) spec.mount else "secret",
    }) };
}

/// The `boru` kind.
pub const boru: sekreto.Definition = sekreto.providerplugin("boru", make);
