// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/src/builtins.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! THE BUILT-IN PROVIDER KINDS - the same four in every port.
//!
//! What makes a kind built in is that it needs nothing of the platform
//! beyond reading a local file: no socket, no TLS, no crypto, no child
//! process. These four are the floor every chain stands on, and a chain
//! that reads secrets from options, the environment, a plaintext `.env`
//! and a mounted secret directory works with no plugin loaded at all.
//! Everything else - the vault clients, the cloud stores, the CLIs - is a
//! plugin, and lives under `../plugins/` (docs/design/plugin-providers.md).
//!
//! A port of typescript/src/provider/builtin.ts, which is canonical.

const std = @import("std");

const sekreto = @import("sekreto.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Config = sekreto.Config;
const KeyValue = sekreto.KeyValue;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;
const Definition = sekreto.Definition;

/// Environment variables: `api.token` from `API_TOKEN`.
pub const EnvProvider = struct {
    config: Config,
    prefix: []const u8,

    pub fn lookup(self: *EnvProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const key = switch (try sekreto.envkey(alloc, name, self.prefix)) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        return .{ .ok = self.config.env.get(key) };
    }

    pub fn describe(self: *EnvProvider, alloc: Allocator) Allocator.Error![]const u8 {
        if (0 == self.prefix.len) {
            return alloc.dupe(u8, "env");
        }
        return std.fmt.allocPrint(alloc, "env:{s}", .{self.prefix});
    }

    pub fn deinit(_: *EnvProvider, _: Allocator) void {}
};

/// A `.env` file, read once, keyed exactly like the environment.
pub const DotenvProvider = struct {
    alloc: Allocator,
    config: Config,
    file: []const u8,
    prefix: []const u8,
    // Loaded once and kept, so the file is read once per process. Its own
    // arena because the parse hands back a mix of borrowed slices and
    // unescaped copies; one free covers both.
    state: std.heap.ArenaAllocator,
    values: ?sekreto.Dotenv,

    fn load(self: *DotenvProvider, alloc: Allocator) Allocator.Error!Answer(sekreto.Dotenv) {
        if (self.values) |values| {
            return .{ .ok = values };
        }

        const keep = self.state.allocator();

        const text = std.Io.Dir.cwd().readFileAlloc(
            self.config.io,
            self.file,
            keep,
            .unlimited,
        ) catch |err| switch (err) {
            // An absent file - or an absent directory - means "no secrets
            // here", exactly like fileprovider. Anything else (permission
            // denied, an unreadable mount) is a store that could not answer,
            // and swallowing it would fall through to a weaker store.
            error.FileNotFound, error.NotDir => "",
            else => return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: dotenv provider cannot read {s}: {s}",
                .{ self.file, @errorName(err) },
            ) },
        };

        const values = try sekreto.parsedotenv(keep, text);
        self.values = values;

        return .{ .ok = values };
    }

    pub fn lookup(self: *DotenvProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const key = switch (try sekreto.envkey(alloc, name, self.prefix)) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        const values = switch (try self.load(alloc)) {
            .err => |message| return .{ .err = message },
            .ok => |loaded| loaded,
        };

        return .{ .ok = values.get(key) };
    }

    pub fn describe(self: *DotenvProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "dotenv:{s}", .{self.file});
    }

    pub fn deinit(self: *DotenvProvider, _: Allocator) void {
        self.state.deinit();
    }
};

/// Literal values, keyed like environment variables. The spec uses this to
/// test chain behaviour without touching the outside world.
pub const MemoryProvider = struct {
    values: []const KeyValue,
    prefix: []const u8,

    pub fn lookup(self: *MemoryProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const key = switch (try sekreto.envkey(alloc, name, self.prefix)) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        for (self.values) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return .{ .ok = entry.value };
            }
        }

        return .{ .ok = null };
    }

    pub fn describe(self: *MemoryProvider, alloc: Allocator) Allocator.Error![]const u8 {
        if (0 == self.prefix.len) {
            return alloc.dupe(u8, "memory");
        }
        return std.fmt.allocPrint(alloc, "memory:{s}", .{self.prefix});
    }

    pub fn deinit(_: *MemoryProvider, _: Allocator) void {}
};

/// A directory of one-secret-per-file entries, keyed like the environment:
/// `api.token` reads `<dir>/API_TOKEN`.
///
/// This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
/// secret, and a systemd credentials directory, so those all work with no
/// further configuration. One trailing newline is stripped - tools that
/// write these files disagree about it, and a newline is never part of a
/// secret on purpose.
pub const FileProvider = struct {
    config: Config,
    dir: []const u8,
    prefix: []const u8,

    pub fn lookup(self: *FileProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const key = switch (try sekreto.envkey(alloc, name, self.prefix)) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        const path = try std.fs.path.join(alloc, &.{ self.dir, key });

        const text = std.Io.Dir.cwd().readFileAlloc(
            self.config.io,
            path,
            alloc,
            .unlimited,
        ) catch |err| switch (err) {
            // An absent file - or an absent directory - means "no secrets
            // here", exactly like a missing .env. Anything else (permission
            // denied, an unreadable mount) is a store that could not answer.
            error.FileNotFound, error.NotDir => return .{ .ok = null },
            else => return .{ .err = try sekreto.fail(
                alloc,
                "sekreto: file provider cannot read {s}: {s}",
                .{ path, @errorName(err) },
            ) },
        };

        var value: []const u8 = text;
        if (0 != value.len and '\n' == value[value.len - 1]) {
            value = value[0 .. value.len - 1];
            if (0 != value.len and '\r' == value[value.len - 1]) {
                value = value[0 .. value.len - 1];
            }
        }

        return .{ .ok = value };
    }

    pub fn describe(self: *FileProvider, alloc: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(alloc, "file:{s}", .{self.dir});
    }

    pub fn deinit(_: *FileProvider, _: Allocator) void {}
};

// ---- the definitions -------------------------------------------------

fn makeenv(alloc: Allocator, config: Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, EnvProvider, .{
        .config = config,
        .prefix = spec.prefix,
    }) };
}

fn makememory(alloc: Allocator, config: Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    _ = config;
    return .{ .ok = try sekreto.provide(alloc, MemoryProvider, .{
        .values = spec.values,
        .prefix = spec.prefix,
    }) };
}

fn makedotenv(alloc: Allocator, config: Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, DotenvProvider, .{
        .alloc = alloc,
        .config = config,
        .file = if (0 != spec.file.len) spec.file else ".env",
        .prefix = spec.prefix,
        .state = std.heap.ArenaAllocator.init(alloc),
        .values = null,
    }) };
}

fn makefile(alloc: Allocator, config: Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, FileProvider, .{
        .config = config,
        .dir = spec.dir,
        .prefix = spec.prefix,
    }) };
}

/// The four built-in kinds, as voxgig/plugin definitions. Every `Sekreto`
/// starts with these in its catalog.
pub const BUILTINS = [_]Definition{
    sekreto.providerplugin("env", makeenv),
    sekreto.providerplugin("memory", makememory),
    sekreto.providerplugin("dotenv", makedotenv),
    sekreto.providerplugin("file", makefile),
};

/// Every kind this library ships, built in or as a plugin, so that an
/// unknown kind can be told from a plugin that was not loaded.
pub const KINDS = struct {
    pub const builtin = [_][]const u8{ "env", "memory", "dotenv", "file" };
    pub const plugin = [_][]const u8{
        "hashicorp",    "boru",        "awssecrets", "awsparams", "gcpsecrets",
        "azuresecrets", "onepassword", "doppler",    "infisical", "secretspec",
    };
};
