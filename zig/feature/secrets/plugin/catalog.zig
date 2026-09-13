// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/catalog.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The definition catalog (§10.1).
//!
//! A definition is registered once and may back many instances. Option
//! shapes are validated AT REGISTRATION, not when a document happens to
//! exercise a key — so a malformed shape fails once, and in the same
//! place everywhere (§9.4). `declare/shape` pins that timing.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const cfg = @import("config.zig");
const ref = @import("ref.zig");

pub const Inst = @import("inst.zig").Inst;

/// A DEFINITION IS DATA WITH FUNCTIONS IN IT, not a class to extend. A
/// document could produce one, which is the property that makes a
/// catalog a data structure rather than a compile-time registry.
pub const LifecycleFn = *const fn (*Inst) t.Err!void;
pub const ReconfigureFn = *const fn (*Inst, ?*v.Value, ?*v.Value) t.Err!void;

pub const Definition = struct {
    name: []const u8,
    shape: ?*v.Value = null,
    define: ?LifecycleFn = null,
    activate: ?LifecycleFn = null,
    deactivate: ?LifecycleFn = null,
    close: ?LifecycleFn = null,
    reconfigure: ?ReconfigureFn = null,
};

pub const Catalog = struct {
    defs: v.List(*Definition),

    pub fn add(c: *Catalog, def: *Definition) t.Err!void {
        if (!ref.checkname(v.vstr(def.name))) {
            return t.fail("plugin_definition_name", v.print("invalid definition name: {s}", .{def.name}), null);
        }
        // Validate the shape HERE. Deferring it to resolution time means
        // a malformed shape surfaces at a different moment in every host
        // that loads it, which is the divergence the stated domain
        // exists to prevent.
        if (!v.isNull(def.shape)) try cfg.checkshape(def.shape);

        for (c.defs.items) |*e| {
            if (std.mem.eql(u8, e.*.name, def.name)) {
                e.* = def;
                return;
            }
        }
        c.defs.append(def) catch @panic("oom");
    }

    pub fn get(c: *Catalog, name: []const u8) ?*Definition {
        for (c.defs.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    pub fn has(c: *Catalog, name: []const u8) bool {
        return c.get(name) != null;
    }

    pub fn names(c: *Catalog) *v.Value {
        const m = v.vmap();
        for (c.defs.items) |d| v.set(m, d.name, v.vbool(true));
        const out = v.vlist();
        for (v.sortedKeys(m)) |k| v.push(out, v.vstr(k));
        return out;
    }
};

pub fn makecatalog() *Catalog {
    const c = v.arena().create(Catalog) catch @panic("oom");
    c.* = .{ .defs = v.List(*Definition).init(v.arena()) };
    return c;
}

/// The callback for a phase, by the name the log and the corpus use.
pub fn callbackFor(d: *Definition, at: []const u8) ?LifecycleFn {
    if (std.mem.eql(u8, at, "define")) return d.define;
    if (std.mem.eql(u8, at, "activate")) return d.activate;
    if (std.mem.eql(u8, at, "deactivate")) return d.deactivate;
    if (std.mem.eql(u8, at, "close")) return d.close;
    return null;
}
