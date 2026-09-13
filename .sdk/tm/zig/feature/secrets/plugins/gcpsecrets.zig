// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/gcpsecrets.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! GCP Secret Manager - a sekreto plugin. Needs HTTPS.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// GCP Secret Manager.
///
/// `api.token` reads secret `api_token` (dots flattened to `_`; Secret
/// Manager ids have no hierarchy and reject dots), latest version. The token
/// comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the GCE/GKE
/// metadata server - so on Google's own platform no credential
/// configuration is needed at all.
///
/// The metadata call itself is plain http to a link-local host by platform
/// design; no credential rides on it, so `checkaddr` guards the Secret
/// Manager address instead.
pub const GcpSecretsProvider = struct {
    alloc: Allocator,
    config: sekreto.Config,
    project: []const u8,
    token: []const u8,
    addr: []const u8,
    metadataaddr: []const u8,
    livetoken: ?[]const u8,
    renewat: i64,

    fn metadata(self: *GcpSecretsProvider, alloc: Allocator) Allocator.Error![]const u8 {
        if (0 != self.metadataaddr.len) {
            return self.metadataaddr;
        }

        if (self.config.env.get("GCE_METADATA_HOST")) |host| {
            if (0 != host.len) {
                return std.fmt.allocPrint(alloc, "http://{s}", .{host});
            }
        }

        return "http://metadata.google.internal";
    }

    fn login(self: *GcpSecretsProvider, alloc: Allocator) Allocator.Error!Answer([]const u8) {
        const configured = httpjson.firstof(self.config, self.token, &.{"GOOGLE_OAUTH_ACCESS_TOKEN"});
        if (0 != configured.len) {
            return .{ .ok = configured };
        }

        const url = try std.fmt.allocPrint(
            alloc,
            "{s}/computeMetadata/v1/instance/service-accounts/default/token",
            .{httpjson.trimslash(try self.metadata(alloc))},
        );

        const headers = [_]httpjson.Header{.{ .name = "Metadata-Flavor", .value = "Google" }};

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, url, &headers, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const access = httpjson.jstr(httpjson.jget(res.body, "access_token"));

        if (200 != res.status or null == access) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: gcp: no token and metadata server did not answer",
                .{},
            ) };
        }

        self.renewat = httpjson.renewafter(self.config.io, httpjson.jnum(httpjson.jget(res.body, "expires_in")));

        return .{ .ok = access.? };
    }

    pub fn lookup(self: *GcpSecretsProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        if (0 == self.project.len) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: gcp: no project", .{}) };
        }

        const addr = if (0 != self.addr.len) self.addr else "https://secretmanager.googleapis.com";

        switch (try sekreto.checkaddr(alloc, addr)) {
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

        const flat = switch (try sekreto.flatname(alloc, name, "_")) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const url = try std.fmt.allocPrint(
            alloc,
            "{s}/v1/projects/{s}/secrets/{s}/versions/latest:access",
            .{ httpjson.trimslash(addr), self.project, flat },
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
            return .{ .err = try sekreto.fail(alloc, "sekreto: gcp error: {d}: {s}", .{ res.status, url }) };
        }

        const data = httpjson.jstr(httpjson.jget(httpjson.jget(res.body, "payload"), "data")) orelse
            return .{ .ok = null };

        // See the aws provider: an undecodable payload is an error, not a
        // miss.
        return .{ .ok = try sekreto.unbase64(alloc, data) orelse
            return .{ .err = try sekreto.fail(alloc, "sekreto: gcp: undecodable secret", .{}) } };
    }

    pub fn describe(self: *GcpSecretsProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "gcpsecrets:{s}", .{self.project});
    }

    pub fn deinit(self: *GcpSecretsProvider, alloc: Allocator) void {
        if (self.livetoken) |token| {
            alloc.free(token);
        }
    }
};

fn make(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, GcpSecretsProvider, .{
        .alloc = alloc,
        .config = config,
        .project = spec.project,
        .token = spec.token,
        .addr = spec.addr,
        .metadataaddr = spec.metadataaddr,
        .livetoken = null,
        .renewat = httpjson.NEVER,
    }) };
}

/// The `gcpsecrets` kind.
pub const gcpsecrets: sekreto.Definition = sekreto.providerplugin("gcpsecrets", make);
