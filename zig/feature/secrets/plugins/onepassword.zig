// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/onepassword.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! 1Password, through a Connect server - a sekreto plugin. Needs HTTPS.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// 1Password, through a Connect server.
///
/// The item titled `api.token` (titles keep their dots), in the named vault.
/// The value is the field with purpose PASSWORD, or the field labelled
/// `value`. A vault that cannot be found is an error - config names it, so
/// its absence is a broken store, not a missing secret.
pub const OnePasswordProvider = struct {
    alloc: Allocator,
    config: sekreto.Config,
    addr: []const u8,
    token: []const u8,
    vault: []const u8,
    vaultid: ?[]const u8,

    fn authheader(self: *OnePasswordProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "Bearer {s}", .{self.token});
    }

    fn resolvevault(self: *OnePasswordProvider, alloc: Allocator, addr: []const u8) Allocator.Error!Answer([]const u8) {
        if (0 == self.vault.len) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: onepassword: no vault", .{}) };
        }

        const url = try std.fmt.allocPrint(alloc, "{s}/v1/vaults", .{addr});
        const headers = [_]httpjson.Header{
            .{ .name = "authorization", .value = try self.authheader(alloc) },
        };

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, url, &headers, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const list = res.body orelse std.json.Value{ .null = {} };

        if (200 != res.status or .array != list) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: onepassword error: {d}: listing vaults",
                .{res.status},
            ) };
        }

        for (list.array.items) |entry| {
            const id = httpjson.jstr(httpjson.jget(entry, "id"));
            const named = httpjson.jstr(httpjson.jget(entry, "name"));

            const hit = (null != id and std.mem.eql(u8, self.vault, id.?)) or
                (null != named and std.mem.eql(u8, self.vault, named.?));

            if (hit and null != id) {
                return .{ .ok = id.? };
            }
        }

        return .{ .err = try sekreto.fail(
            alloc,
            "sekreto: onepassword: no vault named {s}",
            .{self.vault},
        ) };
    }

    pub fn lookup(self: *OnePasswordProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        switch (try sekreto.checkname(alloc, name)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        const addr = httpjson.trimslash(self.addr);
        if (0 == addr.len) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: onepassword: no addr", .{}) };
        }

        switch (try sekreto.checkaddr(alloc, addr)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        if (null == self.vaultid) {
            const found = switch (try self.resolvevault(alloc, addr)) {
                .err => |message| return .{ .err = message },
                .ok => |got| got,
            };
            self.vaultid = try self.alloc.dupe(u8, found);
        }

        const filter = try httpjson.escape(alloc, try std.fmt.allocPrint(alloc, "title eq \"{s}\"", .{name}));

        const findurl = try std.fmt.allocPrint(
            alloc,
            "{s}/v1/vaults/{s}/items?filter={s}",
            .{ addr, self.vaultid.?, filter },
        );

        const headers = [_]httpjson.Header{
            .{ .name = "authorization", .value = try self.authheader(alloc) },
        };

        const found = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, findurl, &headers, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const list = found.body orelse std.json.Value{ .null = {} };

        if (200 != found.status or .array != list) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: onepassword error: {d}: finding {s}",
                .{ found.status, name },
            ) };
        }

        if (0 == list.array.items.len) {
            return .{ .ok = null };
        }

        const itemid = httpjson.jstr(httpjson.jget(list.array.items[0], "id")) orelse "";

        const itemurl = try std.fmt.allocPrint(
            alloc,
            "{s}/v1/vaults/{s}/items/{s}",
            .{ addr, self.vaultid.?, itemid },
        );

        const item = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, itemurl, &headers, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        if (200 != item.status) {
            return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: onepassword error: {d}: reading {s}",
                .{ item.status, name },
            ) };
        }

        const fields = httpjson.jget(item.body, "fields") orelse return .{ .ok = null };
        if (.array != fields) {
            return .{ .ok = null };
        }

        for (fields.array.items) |field| {
            if (httpjson.jstr(httpjson.jget(field, "purpose"))) |purpose| {
                if (std.mem.eql(u8, "PASSWORD", purpose)) {
                    return .{ .ok = httpjson.jstr(httpjson.jget(field, "value")) };
                }
            }
        }

        for (fields.array.items) |field| {
            if (httpjson.jstr(httpjson.jget(field, "label"))) |label| {
                if (std.mem.eql(u8, "value", label)) {
                    return .{ .ok = httpjson.jstr(httpjson.jget(field, "value")) };
                }
            }
        }

        return .{ .ok = null };
    }

    pub fn describe(self: *OnePasswordProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "onepassword:{s}", .{self.vault});
    }

    pub fn deinit(self: *OnePasswordProvider, alloc: Allocator) void {
        if (self.vaultid) |id| {
            alloc.free(id);
        }
    }
};

fn make(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, OnePasswordProvider, .{
        .alloc = alloc,
        .config = config,
        .addr = spec.addr,
        .token = spec.token,
        .vault = spec.vault,
        .vaultid = null,
    }) };
}

/// The `onepassword` kind.
pub const onepassword: sekreto.Definition = sekreto.providerplugin("onepassword", make);
