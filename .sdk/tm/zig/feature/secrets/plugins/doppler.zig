// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/doppler.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! Doppler - a sekreto plugin. Needs HTTPS.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// Doppler.
///
/// The whole config is downloaded once - Doppler's own bulk endpoint - and
/// answered from memory, like a remote .env: `api.token` is the `API_TOKEN`
/// entry. A service token is config-scoped, so project and config are only
/// needed with broader tokens.
pub const DopplerProvider = struct {
    alloc: Allocator,
    config: sekreto.Config,
    token: []const u8,
    project: []const u8,
    dopplerconfig: []const u8,
    addr: []const u8,
    state: std.heap.ArenaAllocator,
    values: ?[]const sekreto.KeyValue,

    fn load(self: *DopplerProvider, alloc: Allocator) Allocator.Error!Answer([]const sekreto.KeyValue) {
        if (self.values) |values| {
            return .{ .ok = values };
        }

        const addr = httpjson.trimslash(if (0 != self.addr.len) self.addr else "https://api.doppler.com");

        switch (try sekreto.checkaddr(alloc, addr)) {
            .err => |message| return .{ .err = message },
            .ok => {},
        }

        var url: std.ArrayList(u8) = .empty;
        try url.appendSlice(alloc, addr);
        try url.appendSlice(alloc, "/v3/configs/config/secrets/download?format=json");

        if (0 != self.project.len) {
            try url.appendSlice(alloc, "&project=");
            try url.appendSlice(alloc, try httpjson.escape(alloc, self.project));
        }
        if (0 != self.dopplerconfig.len) {
            try url.appendSlice(alloc, "&config=");
            try url.appendSlice(alloc, try httpjson.escape(alloc, self.dopplerconfig));
        }

        const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.token});
        const headers = [_]httpjson.Header{.{ .name = "authorization", .value = bearer }};

        const res = switch (try httpjson.fetchjson(alloc, self.config.io, .GET, url.items, &headers, null)) {
            .err => |message| return .{ .err = message },
            .ok => |got| got,
        };

        const body = res.body orelse std.json.Value{ .null = {} };

        if (200 != res.status or .object != body) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: doppler error: {d}", .{res.status}) };
        }

        // Loaded once, so it outlives the lookup's scratch arena.
        const keep = self.state.allocator();
        var values: std.ArrayList(sekreto.KeyValue) = .empty;

        var it = body.object.iterator();
        while (it.next()) |field| {
            const value = httpjson.jstr(field.value_ptr.*) orelse continue;
            try values.append(keep, .{
                .key = try keep.dupe(u8, field.key_ptr.*),
                .value = try keep.dupe(u8, value),
            });
        }

        self.values = values.items;
        return .{ .ok = values.items };
    }

    pub fn lookup(self: *DopplerProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const key = switch (try sekreto.envkey(alloc, name, "")) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        const values = switch (try self.load(alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        for (values) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return .{ .ok = entry.value };
            }
        }

        return .{ .ok = null };
    }

    pub fn describe(self: *DopplerProvider, alloc: Allocator) Allocator.Error![]const u8 {
        if (0 == self.project.len) {
            return alloc.dupe(u8, "doppler");
        }
        return std.fmt.allocPrint(alloc, "doppler:{s}/{s}", .{ self.project, self.dopplerconfig });
    }

    pub fn deinit(self: *DopplerProvider, _: Allocator) void {
        self.state.deinit();
    }
};

fn make(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, DopplerProvider, .{
        .alloc = alloc,
        .config = config,
        .token = spec.token,
        .project = spec.project,
        .dopplerconfig = spec.config,
        .addr = spec.addr,
        .state = std.heap.ArenaAllocator.init(alloc),
        .values = null,
    }) };
}

/// The `doppler` kind.
pub const doppler: sekreto.Definition = sekreto.providerplugin("doppler", make);
