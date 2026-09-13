// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/inst.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The instance and host records.
//!
//! THEY LIVE IN ONE FILE BECAUSE THE CYCLE IS REAL: a definition's
//! callbacks take an instance, an instance points at its host, and a
//! host holds a catalog of definitions. Zig resolves declarations
//! lazily, so it would in fact tolerate the cycle across files — but
//! `catalog.zig` importing `inst.zig` importing `catalog.zig` is a
//! readability trap, and gathering the declarations here is the same
//! shape `c` gets from a forward `typedef`, `ocaml` from `defs.ml` and
//! `haskell` from `Defs.hs`.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const point = @import("point.zig");

/// A scope release. Zig has no closures, so a release is a function plus
/// its context — the same pairing `point.zig` uses for bindings.
pub const ReleaseFn = *const fn (?*anyopaque) void;

pub const ScopeEntry = struct {
    fn_: ?ReleaseFn = null,
    ctx: ?*anyopaque = null,
    done: bool = false,
    /// `acquire` and `release` both count toward `open`; a nested host's
    /// teardown does NOT — a teardown is not an acquisition, and the
    /// inner host keeps its own counter (`nest/open`).
    counts: bool = true,
};

pub const Inst = struct {
    ref: []const u8,
    def: *@import("catalog.zig").Definition,
    status: []const u8 = "declared",
    pos: f64 = 0,
    seq: f64 = 0,
    options: *v.Value,
    state: *v.Value,
    order: ?*v.Value = null,
    /// §11.4's ALWAYS-RELUCTANT rebinding, made concrete: the provider
    /// ref this instance's activation actually selected, per requirement
    /// name. Recomputing the best candidate on every question silently
    /// re-points a live consumer at any better-ranked newcomer, and then
    /// losing the provider it was really using does not restart it.
    selected: *v.Value,
    /// §9.6's `active: false`. THE BAR OUTLIVES THE APPLY THAT SET IT: a
    /// flag consulted only while `apply` ran let a later direct `ready`
    /// bring the instance live, which is the config switch it exists to
    /// be silently ignored.
    barred: bool = false,
    unmet: *v.Value,
    scope: v.List(*ScopeEntry),
    /// Declared in `define`, inserted only when activation SUCCEEDS
    /// (§8.1). Holding them until then is what makes a failed activate
    /// leave nothing behind.
    bindings: v.List(point.Bound),
    inner: ?*Host = null,
    /// Declared in `define`, and VISIBLE while merely `loaded` (§11):
    /// they are data, and hiding them would make the loaded state
    /// useless for introspection.
    exports: *v.Value,
    provides: *v.Value,
    owner: *Host,
};

pub const HostOptions = struct {
    catalog: ?*@import("catalog.zig").Catalog = null,
    reserved: ?*v.Value = null,
    keys: ?*v.Value = null,
    defaults: ?*v.Value = null,
    profile: ?*v.Value = null,
    points: ?*v.Value = null,
    bases: []const BaseFn = &[_]BaseFn{},
    /// §11.3. `restart` (the default) treats provider replacement as an
    /// ordinary runtime operation. `hold` is the strict reading —
    /// deactivating a required instance is `plugin_dependency_held`. NOT
    /// the default, because a station that cannot swap a provider
    /// without a restart has lost the argument for having a plugin
    /// system.
    dependency: []const u8 = "",
};

pub const BaseFn = struct {
    point: []const u8,
    func: *const fn (?*v.Value, ?*anyopaque) t.Err!?*v.Value,
};

pub const Host = struct {
    catalog: *@import("catalog.zig").Catalog,
    reserved: ?*v.Value,
    keys: ?*v.Value,
    defaults: ?*v.Value,
    profile: ?*v.Value,
    points: *v.Value,
    bases: []const BaseFn,
    dependency: []const u8,
    /// Set for the duration of a bulk teardown, so `held` knows this is
    /// a coordinated operation rather than an ad-hoc deactivation.
    coordinated: bool = false,
    instances: v.List(*Inst),
    log: *v.Value,
    events: *v.Value,
    seqn: f64 = 0,
    open: f64 = 0,
    intransition: bool = false,
    /// WHICH callback is running, not merely that one is. §8.1 puts
    /// resource capture in `activate` and §8.3 says `release` outside
    /// `activate` is `plugin_release_scope` — and a boolean alone cannot
    /// tell `activate` from `define`, so it admitted an acquire in
    /// `define` whose scope `unload` would never unwind.
    phase: []const u8 = "",
};

pub const DeclareSpec = struct {
    definition: []const u8 = "",
    options: ?*v.Value = null,
    order: ?*v.Value = null,
    pos: ?f64 = null,
    tag: []const u8 = "",
    /// §9.1: set ONLY by `hostdeclare` — "the host declares those
    /// instances itself, after the user merge, and always wins".
    hostowned: bool = false,
};
