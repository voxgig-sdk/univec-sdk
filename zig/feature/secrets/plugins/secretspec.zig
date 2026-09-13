// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/secretspec.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! SecretSpec (https://secretspec.dev) - a sekreto plugin.
//!
//! Spawns the secretspec CLI, which is why it is a plugin.

const std = @import("std");

const sekreto = @import("sekreto");
const httpjson = @import("httpjson.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const Provider = sekreto.Provider;
const ProviderSpec = sekreto.ProviderSpec;

/// SecretSpec (https://secretspec.dev).
///
/// SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
/// project needs - plus a chain of its own backends to satisfy them from.
/// That makes it the same shape as sekreto one level down, and the reason
/// to support it is the same reason sekreto exists: a project that has
/// already declared its secrets there should not have to declare them
/// again here.
///
/// Read through its CLI, as boru is, because that is the interface it
/// offers a program in another language: `secretspec get API_TOKEN` prints
/// the value on stdout and nothing else. A sekreto name maps to a
/// SecretSpec key exactly as it maps to an environment variable -
/// `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
/// examples use.
///
/// `backend` selects one of SecretSpec's backends (`--provider`, e.g.
/// `keyring` or `dotenv://.env`) and is called `backend` here only because
/// `provider` already means something else in this library.
///
/// A reason is required, not optional: SecretSpec records every read in an
/// audit log and refuses to read at all without one. sekreto sends
/// `sekreto` unless told otherwise, so the audit trail says which tool
/// asked.
pub const SecretspecProvider = struct {
    config: sekreto.Config,
    command: []const u8,
    file: []const u8,
    profile: []const u8,
    backend: []const u8,
    reason: []const u8,
    prefix: []const u8,

    pub fn lookup(self: *SecretspecProvider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        const key = switch (try sekreto.envkey(alloc, name, self.prefix)) {
            .err => |message| return .{ .err = message },
            .ok => |made| made,
        };

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(alloc, self.command);

        if (0 != self.file.len) {
            try argv.append(alloc, "--file");
            try argv.append(alloc, self.file);
        }

        try argv.append(alloc, "get");
        try argv.append(alloc, key);

        if (0 != self.backend.len) {
            try argv.append(alloc, "--provider");
            try argv.append(alloc, self.backend);
        }
        if (0 != self.profile.len) {
            try argv.append(alloc, "--profile");
            try argv.append(alloc, self.profile);
        }

        try argv.append(alloc, "--reason");
        try argv.append(alloc, if (0 != self.reason.len) self.reason else "sekreto");

        const run = std.process.run(alloc, self.config.io, .{
            .argv = argv.items,
            .environ_map = self.config.env,
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
            // The value and one newline, and nothing else.
            var value: []const u8 = run.stdout;
            if (0 != value.len and '\n' == value[value.len - 1]) {
                value = value[0 .. value.len - 1];
            }
            return .{ .ok = value };
        }

        const why = std.mem.trim(u8, run.stderr, " \t\r\n");

        if (try secretspecmiss(alloc, why, key)) {
            return .{ .ok = null };
        }

        if (0 != why.len) {
            return .{ .err = try sekreto.fail(alloc, "sekreto: secretspec error: {s}", .{why}) };
        }

        return .{ .err = try sekreto.fail(alloc, "sekreto: secretspec error: exit {d}", .{exited}) };
    }

    pub fn describe(self: *SecretspecProvider, alloc: Allocator) Allocator.Error![]const u8 {
        if (0 == self.backend.len) {
            return alloc.dupe(u8, "secretspec");
        }
        return std.fmt.allocPrint(alloc, "secretspec:{s}", .{self.backend});
    }

    pub fn deinit(_: *SecretspecProvider, _: Allocator) void {}
};

/// Does this SecretSpec failure mean "no such secret" rather than "I could
/// not answer"?
///
/// SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
/// not declare and one declared with no value, and both are misses: this
/// store does not hold it, so the chain carries on.
///
/// MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
/// `Provider backend 'keyring' not found`, which is a store that could not
/// answer at all - and reading that as a miss is the worst failure this
/// library has, because the chain then falls through to a weaker store
/// without saying so. The key is required to appear, so the two cannot be
/// confused.
fn secretspecmiss(alloc: Allocator, why: []const u8, key: []const u8) Allocator.Error!bool {
    const phrase = try std.fmt.allocPrint(alloc, "Secret '{s}' not found", .{key});
    return null != std.mem.indexOf(u8, why, phrase);
}

fn make(alloc: Allocator, config: sekreto.Config, spec: ProviderSpec) Allocator.Error!Answer(Provider) {
    return .{ .ok = try sekreto.provide(alloc, SecretspecProvider, .{
        .config = config,
        .command = if (0 != spec.command.len) spec.command else "secretspec",
        .file = spec.file,
        .profile = spec.profile,
        .backend = spec.backend,
        .reason = spec.reason,
        .prefix = spec.prefix,
    }) };
}

/// The `secretspec` kind.
pub const secretspec: sekreto.Definition = sekreto.providerplugin("secretspec", make);
