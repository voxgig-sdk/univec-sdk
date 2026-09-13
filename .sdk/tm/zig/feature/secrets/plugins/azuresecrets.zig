// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/azuresecrets.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Azure Key Vault - a sekreto plugin. Needs HTTPS.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// Azure Key Vault.
///
/// `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
/// names allow nothing else), current version. The token comes from config,
/// then a client-credentials login when tenant/clientid/clientsecret are
/// given, then the IMDS managed-identity endpoint - so on Azure's own
/// platform no credential configuration is needed.
///
/// As with GCP, the IMDS call is plain http to a link-local host by platform
/// design and carries no credential; the login and vault addresses are
/// `checkaddr`-guarded.
pub const AzureSecretsProvider = struct {
    alloc: Allocator,
    config: sekreto.Config,
    vault: []const u8,
    token: []const u8,
    tenant: []const u8,
    clientid: []const u8,
    clientsecret: []const u8,
    loginaddr: []const u8,
    imdsaddr: []const u8,
    apiversion: []const u8,
    livetoken: ?[]const u8,
    renewat: i64,

    const RESOURCE = "https://vault.azure.net";

    fn login(self: *AzureSecretsProvider, alloc: Allocator) Allocator.Error!Answer([]const u8) {
        if (0 != self.token.len) {
            return .{ .ok = self.token };
        }

        if (0 != self.tenant.len and 0 != self.clientid.len and 0 != self.clientsecret.len) {
            const loginaddr = if (0 != self.loginaddr.len)
                self.loginaddr
            else
                "https://login.microsoftonline.com";

            switch (try sekreto.checkaddr(alloc, loginaddr)) {
                .err => |message| return .{ .err = message },
                .ok => {},
            }

            const url = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}/oauth2/v2.0/token",
                .{ httpjson.trimslash(loginaddr), self.tenant },
            );

            const form = try std.fmt.allocPrint(
                alloc,
                "grant_type=client_credentials&client_id={s}&client_secret={s}&scope={s}",
                .{
                    try httpjson.escape(alloc, self.clientid),
                    try httpjson.escape(alloc, self.clientsecret),
                    try httpjson.escape(alloc, RESOURCE ++ "/.default"),
                },
            );

            const headers = [_]httpjson.Header{
                .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            };

            const res = switch (try httpjson.fetchjson(alloc, self.config.io, .POST, url, &headers, form)) {
                .err => |message| return .{ .err = message },
                .ok => |got| got,
            };

            const access = httpjson.jstr(httpjson.jget(res.body, "access_token"));

            if (200 != res.status or null == access) {
                return .{ .err = try sekreto.fail(
                    alloc,
                    "sekreto: azure login failed: {d}",
                    .{res.status},
                ) };
            }

            self.renewat = httpjson.renewafter(self.config.io, httpjson.jnum(httpjson.jget(res.body, "expires_in")));
            return .{ .ok = access.? };
        }

        const imds = if (0 != self.imdsaddr.len) self.imdsaddr else "http://169.254.169.254";

        const url = try std.fmt.allocPrint(
            alloc,
            "{s}/metadata/identity/oauth2/token?api-version=2018-02-01&resource={s}",
            .{ httpjson.trimslash(imds), try httpjson.escape(alloc, RESOURCE) },
        );

        const headers = [_]httpjson.Header{.{ .name = "Metadata", .value = "true" }};

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, url, &headers, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const access = httpjson.jstr(httpjson.jget(res.body, "access_token"));

        if (200 != res.status or null == access) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: azure: no token, no client credentials, and IMDS did not answer",
                .{},
            ) };
        }

        self.renewat = httpjson.renewafter(self.config.io, httpjson.jnum(httpjson.jget(res.body, "expires_in")));
        return .{ .ok = access.? };
    }

    pub fn lookup(self: *AzureSecretsProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        if (0 == self.vault.len) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: azure: no vault", .{}) };
        }

        // Only an explicit scheme is a URL; a vault NAMED httpvault must
        // still become https://httpvault.vault.azure.net.
        const vaulturl = if (std.mem.startsWith(u8, self.vault, "http://") or
            std.mem.startsWith(u8, self.vault, "https://"))
            self.vault
        else
            try std.fmt.allocPrint(alloc, "https://{s}.vault.azure.net", .{self.vault});

        switch (try sekreto.checkaddr(alloc, vaulturl)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        if (null == self.livetoken or httpjson.nowms(self.config.io) >= self.renewat) {
            const fresh = switch (try self.login(alloc)) {
                .err => |message| return .{ .err = message },
                .ok => |got| got,
            };
            if (self.livetoken) |old| {
                self.alloc.free(old);
            }
            self.livetoken = try self.alloc.dupe(u8, fresh);
        }

        const flat = switch (try sekreto.flatname(alloc, name, "-")) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const version = if (0 != self.apiversion.len) self.apiversion else "7.4";

        const url = try std.fmt.allocPrint(
            alloc,
            "{s}/secrets/{s}?api-version={s}",
            .{ httpjson.trimslash(vaulturl), flat, version },
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
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: azure error: {d}: {s}",
                .{ res.status, httpjson.nakedurl(url) },
            ) };
        }

        return .{ .ok = httpjson.jstr(httpjson.jget(res.body, "value")) };
    }

    pub fn describe(self: *AzureSecretsProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "azuresecrets:{s}", .{self.vault});
    }

    pub fn deinit(self: *AzureSecretsProvider, alloc: Allocator) void {
        if (self.livetoken) |token| {
            alloc.free(token);
        }
    }
};

fn make(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, AzureSecretsProvider, .{
        .alloc = alloc,
        .config = config,
        .vault = spec.vault,
        .token = spec.token,
        .tenant = spec.tenant,
        .clientid = spec.clientid,
        .clientsecret = spec.clientsecret,
        .loginaddr = spec.loginaddr,
        .imdsaddr = spec.imdsaddr,
        .apiversion = spec.apiversion,
        .livetoken = null,
        .renewat = httpjson.NEVER,
    }) };
}

/// The `azuresecrets` kind.
pub const azuresecrets: sekreto.Definition = sekreto.providerplugin("azuresecrets", make);
