// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/infisical.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Infisical - a sekreto plugin. Needs HTTPS.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// Infisical.
///
/// `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
/// convention is environment-style keys) at a secret path in one environment
/// of a project. sekreto.Auth is a token, or a universal-auth (machine identity)
/// login with clientid/clientsecret.
pub const InfisicalProvider = struct {
    alloc: Allocator,
    config: sekreto.Config,
    addr: []const u8,
    token: []const u8,
    clientid: []const u8,
    clientsecret: []const u8,
    project: []const u8,
    environment: []const u8,
    path: []const u8,
    livetoken: ?[]const u8,
    renewat: i64,

    fn login(self: *InfisicalProvider, alloc: Allocator, addr: []const u8) Allocator.Error!Answer([]const u8) {
        if (0 != self.token.len) {
            return .{ .ok = self.token };
        }

        if (0 == self.clientid.len or 0 == self.clientsecret.len) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: infisical: no token and no client credentials",
                .{},
            ) };
        }

        const url = try std.fmt.allocPrint(alloc, "{s}/api/v1/auth/universal-auth/login", .{addr});

        const body = try httpjson.jsonobject(alloc, &.{
            .{ .key = "clientId", .value = self.clientid },
            .{ .key = "clientSecret", .value = self.clientsecret },
        });

        const headers = [_]httpjson.Header{
            .{ .name = "content-type", .value = "application/json" },
        };

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .POST, url, &headers, body)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const access = httpjson.jstr(httpjson.jget(res.body, "accessToken"));

        if (200 != res.status or null == access) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: infisical login failed: {d}",
                .{res.status},
            ) };
        }

        self.renewat = httpjson.renewafter(self.config.io, httpjson.jnum(httpjson.jget(res.body, "expiresIn")));

        return .{ .ok = access.? };
    }

    pub fn lookup(self: *InfisicalProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const addr = httpjson.trimslash(if (0 != self.addr.len) self.addr else "https://app.infisical.com");

        switch (try sekreto.checkaddr(alloc, addr)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        if (0 == self.project.len or 0 == self.environment.len) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: infisical: no project/environment", .{}) };
        }

        if (null == self.livetoken or httpjson.nowms(self.config.io) >= self.renewat) {
            const fresh = switch (try self.login(alloc, addr)) {
                .err => |message| return .{ .err = message },
                .ok => |got| got,
            };
            if (self.livetoken) |old| {
                self.alloc.free(old);
            }
            self.livetoken = try self.alloc.dupe(u8, fresh);
        }

        const key = switch (try sekreto.envkey(alloc, name, "")) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        const url = try std.fmt.allocPrint(
            alloc,
            "{s}/api/v3/secrets/raw/{s}?workspaceId={s}&environment={s}&secretPath={s}",
            .{
                addr,
                key,
                try httpjson.escape(alloc, self.project),
                try httpjson.escape(alloc, self.environment),
                try httpjson.escape(alloc, if (0 != self.path.len) self.path else "/"),
            },
        );

        const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.livetoken.?});
        const headers = [_]httpjson.Header{.{ .name = "authorization", .value = bearer }};

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, url, &headers, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        if (404 == res.status) {
            return .{ .ok = null };
        }

        if (200 != res.status) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: infisical error: {d}", .{res.status}) };
        }

        return .{ .ok = httpjson.jstr(httpjson.jget(httpjson.jget(res.body, "secret"), "secretValue")) };
    }

    pub fn describe(self: *InfisicalProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "infisical:{s}/{s}", .{ self.project, self.environment });
    }

    pub fn deinit(self: *InfisicalProvider, alloc: Allocator) void {
        if (self.livetoken) |token| {
            alloc.free(token);
        }
    }
};

fn make(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, InfisicalProvider, .{
        .alloc = alloc,
        .config = config,
        .addr = spec.addr,
        .token = spec.token,
        .clientid = spec.clientid,
        .clientsecret = spec.clientsecret,
        .project = spec.project,
        .environment = spec.environment,
        .path = spec.path,
        .livetoken = null,
        .renewat = httpjson.NEVER,
    }) };
}

/// The `infisical` kind.
pub const infisical: sekreto.Definition = sekreto.providerplugin("infisical", make);
