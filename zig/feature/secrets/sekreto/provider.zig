// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/src/provider.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! What a provider is, what its declarative form looks like, and how a
//! provider kind becomes a voxgig/plugin definition.
//!
//! A provider answers one question: "do you have this secret?" It returns
//! the value, or null to mean "ask the next one". Nothing else about a
//! provider is visible to the caller - which is the point: an app reads
//! `api.token` and never learns whether it came from the environment, a
//! .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
//!
//! Two failure shapes, and they are never interchangeable. A store that
//! does not hold the secret is a MISS (`.ok = null`) - the chain carries
//! on. A store that could not answer - bad credentials, unreachable host,
//! missing configuration - is an ERROR (`.err`): falling through there
//! would quietly reach for a weaker store.
//!
//! `Provider` is a VTABLE, not the tagged union it used to be. The union
//! named all fourteen kinds, and a core that names every kind links
//! every kind; the set is open now - four built in here, ten under
//! `../plugins/`, and any number a calling project makes with
//! `providerplugin` - so the core holds a pointer and three function
//! pointers and knows nothing else.
//!
//! A port of typescript/src/provider/support.ts, which is canonical.

const std = @import("std");

const plugin = @import("plugin");
const sekreto = @import("sekreto.zig");

const Allocator = std.mem.Allocator;
const Answer = sekreto.Answer;
const Found = sekreto.Found;
const pv = plugin.value;
const pt = plugin.types;

/// A voxgig/plugin definition: what `Sekreto` builds a provider from.
pub const Definition = plugin.host.Definition;
pub const Inst = plugin.host.Inst;

/// What the library needs from the process it runs in.
///
/// Passed in rather than reached for, because Zig 0.16 hands both to `main`
/// and because a library that samples global state cannot be tested. The
/// environment is read by the `env` provider and by every store that
/// follows its own ecosystem's convention (AWS_*, GCE_METADATA_HOST); `io`
/// is what opens sockets, reads files and runs the boru binary.
pub const Config = struct {
    io: std.Io,
    env: *const std.process.Environ.Map,
};

/// One literal secret, for the `memory` provider. A list rather than a map
/// because the spec pins the whole map and randomised iteration would make
/// that comparison depend on the run.
pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Logging in for a token instead of being handed one.
pub const Auth = struct {
    /// `kubernetes` or `approle`.
    method: []const u8 = "",
    /// The auth mount, defaulting to the method name.
    mount: []const u8 = "",
    /// kubernetes: the Vault role to log in as.
    role: []const u8 = "",
    /// kubernetes: the service-account JWT itself (tests).
    jwt: ?[]const u8 = null,
    /// kubernetes: where the JWT lives; the conventional pod path by default.
    jwtfile: []const u8 = "",
    /// approle: the role and secret ids.
    roleid: []const u8 = "",
    secretid: []const u8 = "",
};

/// The declarative form of a provider, as used in config and in the shared
/// spec: a `kind` naming a built-in or a plugin, plus that kind's own
/// configuration.
///
/// Every string defaults to empty rather than being optional: "not
/// configured" and "configured empty" mean the same thing for every field
/// here, and one representation is one fewer thing to get wrong.
///
/// A spec reaches its plugin as the instance's OPTIONS, the voxgig/plugin
/// dynamic value: `Sekreto.init` encodes it with `optionsof` (the field
/// names are the keys, as they are in every port's spec) and the
/// definition's `define` reads it back with `specof`. Every string is
/// COPIED into the plugin arena on the way in, so the caller's strings
/// need not outlive the chain.
pub const ProviderSpec = struct {
    kind: []const u8,
    /// The store name `Sekreto.getfrom` addresses. Defaults to `kind`.
    name: []const u8 = "",
    prefix: []const u8 = "",
    /// dotenv: the file to read. secretspec: the declaration file.
    file: []const u8 = "",
    /// memory: literal values, keyed like environment variables.
    values: []const KeyValue = &.{},
    /// file: the directory of one-secret-per-file entries.
    dir: []const u8 = "",
    /// hashicorp / boru (wire) / gcp / 1password / doppler / infisical: the
    /// base URL.
    addr: []const u8 = "",
    /// hashicorp / boru (wire) / gcp / azure / 1password / doppler /
    /// infisical: the access token.
    token: []const u8 = "",
    /// hashicorp / boru (wire): the KV mount (default `secret`).
    mount: []const u8 = "",
    /// hashicorp: KV engine version, 1 or 2 (default 2). Zero means unset.
    kv: i64 = 0,
    /// hashicorp: Vault Enterprise namespace (X-Vault-Namespace).
    vaultnamespace: []const u8 = "",
    /// hashicorp: log in for a token instead of being handed one.
    auth: ?Auth = null,
    /// boru / secretspec: the executable to run (default: the kind's own
    /// name).
    command: []const u8 = "",
    /// secretspec: the profile to read (`--profile`).
    profile: []const u8 = "",
    /// secretspec: which of ITS backends to read from (`--provider`), e.g.
    /// `keyring` or `dotenv://.env`. Named `backend` here because
    /// `provider` already means a sekreto provider.
    backend: []const u8 = "",
    /// secretspec: the audit reason recorded for the read (`--reason`).
    /// SecretSpec refuses to read without one.
    reason: []const u8 = "",
    /// boru: the namespace qualifying the alias.
    namespace: []const u8 = "",
    /// boru: the vault home, passed as BORU_HOME.
    home: []const u8 = "",
    /// aws: region and credentials; the standard AWS_* environment
    /// variables fill whichever are not given.
    region: []const u8 = "",
    keyid: []const u8 = "",
    secret: []const u8 = "",
    session: []const u8 = "",
    /// gcp / doppler / infisical: the project (GCP project id, Doppler
    /// project slug, Infisical workspace id).
    project: []const u8 = "",
    /// azure: the Key Vault name or full URL. 1password: the vault name or id.
    vault: []const u8 = "",
    /// azure: client-credential login. infisical: universal-auth login
    /// (tenant is Azure-only).
    tenant: []const u8 = "",
    clientid: []const u8 = "",
    clientsecret: []const u8 = "",
    /// azure: where to log in / where IMDS answers. gcp: where the metadata
    /// server answers.
    loginaddr: []const u8 = "",
    imdsaddr: []const u8 = "",
    metadataaddr: []const u8 = "",
    /// azure: the Key Vault API version (default 7.4).
    apiversion: []const u8 = "",
    /// doppler: the config slug (with `project`).
    config: []const u8 = "",
    /// infisical: the environment slug and secret path.
    environment: []const u8 = "",
    path: []const u8 = "",
};

// ---- the provider ----------------------------------------------------

/// A source of secrets: a pointer and three function pointers.
///
/// `lookup`'s `alloc` is scratch for one lookup; what a provider keeps
/// between lookups it allocates from its own allocator instead. `describe`
/// ALWAYS allocates, even for a kind whose description is a constant: a
/// caller that sometimes gets a literal and sometimes an allocation cannot
/// free either one safely. `deinit` releases what the provider holds AND
/// the provider itself.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        lookup: *const fn (*anyopaque, Allocator, []const u8) Allocator.Error!Found,
        describe: *const fn (*anyopaque, Allocator) Allocator.Error![]const u8,
        deinit: *const fn (*anyopaque, Allocator) void,
    };

    /// The value, null if this provider does not have it, or the message of
    /// a failure.
    pub fn lookup(self: Provider, alloc: Allocator, name: []const u8) Allocator.Error!Found {
        return self.vtable.lookup(self.ptr, alloc, name);
    }

    /// A short description, shown by `Sekreto.sources()`. It must lead with
    /// the kind: everything before the first `:` is the default store name.
    pub fn describe(self: Provider, alloc: Allocator) Allocator.Error![]const u8 {
        return self.vtable.describe(self.ptr, alloc);
    }

    pub fn deinit(self: Provider, alloc: Allocator) void {
        self.vtable.deinit(self.ptr, alloc);
    }
};

/// A concrete provider - any struct with `lookup`, `describe` and `deinit`
/// methods of the shapes above - behind the vtable. The struct is expected
/// to have been allocated with the allocator its `deinit` will be handed,
/// which is what `provide` guarantees.
pub fn adapt(comptime T: type, ptr: *T) Provider {
    const Gen = struct {
        fn lookup(p: *anyopaque, alloc: Allocator, name: []const u8) Allocator.Error!Found {
            const self: *T = @ptrCast(@alignCast(p));
            return self.lookup(alloc, name);
        }

        fn describe(p: *anyopaque, alloc: Allocator) Allocator.Error![]const u8 {
            const self: *T = @ptrCast(@alignCast(p));
            return self.describe(alloc);
        }

        fn deinit(p: *anyopaque, alloc: Allocator) void {
            const self: *T = @ptrCast(@alignCast(p));
            self.deinit(alloc);
            alloc.destroy(self);
        }

        const vtable = Provider.VTable{
            .lookup = lookup,
            .describe = describe,
            .deinit = deinit,
        };
    };

    return .{ .ptr = ptr, .vtable = &Gen.vtable };
}

/// Allocate a concrete provider and present it as a `Provider`. Every
/// built-in and every shipped plugin builds its provider this way.
pub fn provide(alloc: Allocator, comptime T: type, value: T) Allocator.Error!Provider {
    const ptr = try alloc.create(T);
    ptr.* = value;
    return adapt(T, ptr);
}

// ---- the spec as plugin options --------------------------------------

/// The export key under which a provider definition publishes the
/// provider it built. `Sekreto` reads `<ref>/provider` off the host.
pub const PROVIDER_EXPORT = "provider";

/// The voxgig/plugin error code a sekreto failure travels under when it is
/// raised inside a definition's `define`.
///
/// plugin wraps a code-less error raised by a callback as
/// `plugin_define_failed`, and keeps an error that already carries a
/// code. A provider that refuses its own configuration - `kv: 3`, a
/// missing project - answers with a message, and that message is pinned
/// by the spec byte for byte, so it must come back out of the host
/// exactly as it went in. `providerplugin` gives it this code on the way
/// in; `Sekreto` turns it back into the same message on the way out.
pub const ERROR_CODE = "sekreto_error";

fn setstr(m: *pv.Value, key: []const u8, text: []const u8) void {
    if (0 != text.len) {
        pv.set(m, key, pv.vstr(pv.dupe(text)));
    }
}

/// A spec as the options map a plugin instance carries: one key per
/// field that is set, named as the field is - the spec's own key names in
/// every port. Strings are copied into the plugin arena.
pub fn optionsof(spec: ProviderSpec) *pv.Value {
    const out = pv.vmap();

    inline for (std.meta.fields(ProviderSpec)) |f| {
        const value = @field(spec, f.name);

        if ([]const u8 == f.type) {
            setstr(out, f.name, value);
        } else if (i64 == f.type) {
            if (0 != value) {
                pv.set(out, f.name, pv.vnum(@floatFromInt(value)));
            }
        } else if (?Auth == f.type) {
            if (value) |auth| {
                const m = pv.vmap();
                setstr(m, "method", auth.method);
                setstr(m, "mount", auth.mount);
                setstr(m, "role", auth.role);
                if (auth.jwt) |jwt| {
                    pv.set(m, "jwt", pv.vstr(pv.dupe(jwt)));
                }
                setstr(m, "jwtfile", auth.jwtfile);
                setstr(m, "roleid", auth.roleid);
                setstr(m, "secretid", auth.secretid);
                pv.set(out, f.name, m);
            }
        } else if ([]const KeyValue == f.type) {
            if (0 != value.len) {
                const m = pv.vmap();
                for (value) |pair| {
                    pv.set(m, pair.key, pv.vstr(pv.dupe(pair.value)));
                }
                pv.set(out, f.name, m);
            }
        } else {
            @compileError("ProviderSpec field with no options encoding: " ++ f.name);
        }
    }

    return out;
}

/// The spec a plugin instance's options describe: the inverse of
/// `optionsof`. The strings are the options' own, which live in the
/// plugin arena for the life of the process.
pub fn specof(options: ?*const pv.Value) ProviderSpec {
    var spec = ProviderSpec{ .kind = "" };

    inline for (std.meta.fields(ProviderSpec)) |f| {
        const given = pv.get(options, f.name);

        if ([]const u8 == f.type) {
            @field(spec, f.name) = pv.asStr(given);
        } else if (i64 == f.type) {
            if (pv.isNum(given)) {
                @field(spec, f.name) = @intFromFloat(pv.asNum(given));
            }
        } else if (?Auth == f.type) {
            if (pv.isMap(given)) {
                const jwt = pv.get(given, "jwt");
                @field(spec, f.name) = .{
                    .method = pv.asStr(pv.get(given, "method")),
                    .mount = pv.asStr(pv.get(given, "mount")),
                    .role = pv.asStr(pv.get(given, "role")),
                    .jwt = if (pv.isStr(jwt)) pv.asStr(jwt) else null,
                    .jwtfile = pv.asStr(pv.get(given, "jwtfile")),
                    .roleid = pv.asStr(pv.get(given, "roleid")),
                    .secretid = pv.asStr(pv.get(given, "secretid")),
                };
            }
        } else if ([]const KeyValue == f.type) {
            if (pv.isMap(given)) {
                const keys = pv.keys(given);
                const pairs = pv.arena().alloc(KeyValue, keys.len) catch @panic("sekreto: out of memory");
                for (keys, 0..) |key, at| {
                    pairs[at] = .{ .key = key, .value = pv.asStr(pv.get(given, key)) };
                }
                @field(spec, f.name) = pairs;
            }
        } else {
            @compileError("ProviderSpec field with no options encoding: " ++ f.name);
        }
    }

    return spec;
}

// ---- providers as voxgig/plugin definitions --------------------------

/// What a definition's `define` needs that the plugin host cannot carry:
/// the allocator, the process config, and somewhere to put the provider
/// it built. voxgig/plugin's values are numbers and strings, not
/// pointers, so `define` exports the INDEX of its provider in `made` and
/// `Sekreto.init` reads it back through the host's exports.
///
/// MODULE-GLOBAL, for the reason voxgig/plugin's own zig port keeps its
/// error slot global: a lifecycle callback is a bare function pointer
/// with no context, so what it needs travels beside the call. It is set
/// for the duration of `Sekreto.init` and null otherwise; two threads
/// constructing chains at once would race it, and this port - like the
/// plugin port under it - does not claim to support that.
pub const Building = struct {
    alloc: Allocator,
    config: Config,
    made: std.ArrayList(Provider) = .empty,
    /// Allocation failure inside a callback, which cannot cross the
    /// plugin boundary as a zig error and is raised again on the far side.
    oom: bool = false,
};

pub var building: ?*Building = null;

/// How a kind builds its provider: from the allocator, the process config
/// and the spec. A refusal is a returned message, never a zig error.
pub const MakeFn = *const fn (Allocator, Config, ProviderSpec) Allocator.Error!Answer(Provider);

/// A provider kind, as a voxgig/plugin definition.
///
/// This is the whole bridge between the two libraries. The definition's
/// `name` is the `kind` a ProviderSpec names; its `define` reads the spec
/// off the instance's options, builds the provider with `make`, and
/// exports it. Nothing runs at `activate`: a provider opens nothing until
/// its first lookup, so there is nothing to capture - a provider that does
/// hold a resource acquires it there and lets the instance scope unwind
/// it.
///
/// Every built-in and every plugin is made this way, so a custom provider
/// kind is one call, at comptime:
///
///     pub const mystore = sekreto.providerplugin("mystore", make);
///
/// where `make` returns `sekreto.provide(alloc, MyStore, .{ ... })` or the
/// message of its refusal.
pub fn providerplugin(comptime kind: []const u8, comptime makefn: MakeFn) Definition {
    const Gen = struct {
        fn define(inst: *Inst) pt.Err!void {
            const b = building orelse {
                return pt.fail("plugin_bad_state", "sekreto: a provider was built outside Sekreto.init", null);
            };

            const spec = specof(inst.options);

            const made = makefn(b.alloc, b.config, spec) catch {
                b.oom = true;
                return pt.fail(ERROR_CODE, "sekreto: out of memory", null);
            };

            switch (made) {
                .err => |message| {
                    // The message is the caller's allocation; the host keeps
                    // its own copy, and so does the `cause` that comes back
                    // out byte for byte.
                    defer b.alloc.free(message);
                    const details = pv.vmap();
                    pv.set(details, "ref", pv.vstr(inst.ref));
                    pv.set(details, "cause", pv.vstr(pv.dupe(message)));
                    return pt.fail(ERROR_CODE, message, details);
                },
                .ok => |provider| {
                    b.made.append(b.alloc, provider) catch {
                        provider.deinit(b.alloc);
                        b.oom = true;
                        return pt.fail(ERROR_CODE, "sekreto: out of memory", null);
                    };
                    plugin.host.exportvalue(inst, PROVIDER_EXPORT, pv.vnum(@floatFromInt(b.made.items.len - 1)));
                },
            }
        }
    };

    return .{ .name = kind, .define = Gen.define };
}
