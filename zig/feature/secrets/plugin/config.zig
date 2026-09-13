// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/config.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! The declarative document (§9): normalization, and the ten-level
//! precedence ladder.
//!
//! TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
//!
//! `normalizeconfig` normalizes STRUCTURE and ENTRY KEYS. It does not
//! merge options, and cannot: §9.4 makes merge behaviour a property of
//! the definition's option SHAPE, which normalization has never seen. A
//! normalizer that flattened the option layers would make
//! `$MERGE: append` unimplementable at load time, because the layers it
//! must concatenate would already be collapsed.
//!
//! `resolveoptions` applies the ladder, and it is the only place that
//! knows the shape.

const std = @import("std");
const v = @import("value.zig");
const t = @import("types.zig");
const ref = @import("ref.zig");

/// §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
/// too. A configuration surface that can disable the thing reading it is
/// not a surface, it is a trap.
fn checkreserved(r: []const u8, reserved: ?*v.Value) t.Err!void {
    if (!v.isList(reserved) or v.len(reserved) == 0) return;
    const name = ref.refname(r);
    for (v.items(reserved)) |x| {
        if (v.isStr(x) and std.mem.eql(u8, v.asStr(x), name)) {
            return t.fail("plugin_ref_reserved", v.print("ref is reserved by the host: {s}", .{r}), t.details1("ref", v.vstr(r)));
        }
    }
}

const Entries = struct { map: *v.Value, order: *v.Value };

/// Both document forms reduce to {ref -> entry} plus the order the form
/// implies: array POSITION for the array form, sorted refs for the map
/// form.
fn entriesof(src: ?*v.Value) t.Err!Entries {
    const out = Entries{ .map = v.vmap(), .order = v.vlist() };
    if (v.isNull(src)) return out;

    if (v.isList(src)) {
        for (v.items(src)) |item| {
            const r = try ref.canonref(v.get(item, "ref"));
            v.set(out.map, r, item);
            v.push(out.order, v.vstr(r));
        }
        return out;
    }

    // Map-form refs arrive as KEYS, through a different path than an
    // array element's `ref` field — and must canonicalize the same way.
    for (v.keys(src)) |k| {
        v.set(out.map, try ref.canonrefs(k), v.get(src, k));
    }
    // Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase
    // refs sort identically under all three, so only mixed input
    // discriminates: '@' is 0x40, uppercase 0x41-0x5A, lowercase
    // 0x61-0x7A.
    for (v.sortedKeys(out.map)) |k| v.push(out.order, v.vstr(k));
    return out;
}

/// PRESENT WINS, EVEN WHEN THE VALUE IS NULL. The canonical is
/// `src && undefined !== src[key]`, and in JavaScript a key holding
/// `null` passes that test — so a profile's `order: null` clears a base
/// ordering block and `active: null` over a base `active: true` is
/// falsy, and barred. Testing for non-null instead treated an authored
/// null as an absent key, which is §9.1's distinction inverted.
fn pick(src: ?*v.Value, key: []const u8, dflt: ?*v.Value) ?*v.Value {
    if (v.isMap(src) and v.has(src, key)) return v.get(src, key);
    return dflt;
}

fn listhas(list: ?*v.Value, s: []const u8) bool {
    for (v.items(list)) |x| {
        if (v.isStr(x) and std.mem.eql(u8, v.asStr(x), s)) return true;
    }
    return false;
}

pub fn normalizeconfig(input: ?*v.Value) t.Err!*v.Value {
    var doc = v.get(input, "doc");
    if (!v.isMap(doc)) doc = v.vmap();
    const keyspec = v.get(input, "keys");
    const ikey = if (v.isStr(v.get(keyspec, "instance"))) v.asStr(v.get(keyspec, "instance")) else "instance";
    const dkey = if (v.isStr(v.get(keyspec, "default"))) v.asStr(v.get(keyspec, "default")) else "default";
    const reserved = v.get(input, "reserved");
    const profile = v.get(input, "profile");

    // The rename is applied at TWO PLACES AND NO OTHERS: the document
    // root, and every profile.<name> overlay root (§9.1). A rename
    // applied only at the root would leave `profile.prod.sdk`
    // untranslated and silently drop every environment override the host
    // depends on. Recursing further would be worse: option data is the
    // definition's.
    const baseinst = v.get(doc, ikey);
    var basedef = v.get(doc, dkey);
    if (!v.isMap(basedef)) basedef = v.vmap();

    const overlay = if (v.isStr(profile)) v.get(v.get(doc, "profile"), v.asStr(profile)) else v.vnull();
    const overinst = if (v.isMap(overlay)) v.get(overlay, ikey) else v.vnull();
    var overdef = if (v.isMap(overlay)) v.get(overlay, dkey) else v.vnull();
    if (!v.isMap(overdef)) overdef = v.vmap();

    const base = try entriesof(baseinst);
    const over = try entriesof(overinst);

    for ([_]*v.Value{ base.map, over.map, basedef, overdef }) |m| {
        for (v.keys(m)) |k| try checkreserved(k, reserved);
    }

    // A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the
    // hard way: deriving order from a partial array silently dropped
    // config-activated features. Refs in the base but absent from the
    // overlay still load, in sorted position AFTER the listed ones. A
    // profile may also INTRODUCE a ref the base never declared.
    const order = v.vlist();
    for (v.items(over.order)) |x| {
        if (!listhas(order, v.asStr(x))) v.push(order, v.vstr(v.asStr(x)));
    }
    // The remainder keeps the BASE's own order — array position for the
    // array form, sorted refs for the map form. Re-sorting here would
    // discard an array document's positional order entirely, which is
    // the one thing the array form exists to express.
    for (v.items(base.order)) |x| {
        if (!listhas(order, v.asStr(x))) v.push(order, v.vstr(v.asStr(x)));
    }

    const instance = v.vmap();
    for (v.items(order), 0..) |rv, i| {
        const r = v.asStr(rv);
        const b = v.get(base.map, r);
        const o = v.get(over.map, r);

        // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE
        // RESULT (§9.3). A safety rule, not a tidiness one: if the
        // overlay had its defaults filled in before merging it would
        // carry a synthesized active:true and overwrite a base's false —
        // silently re-enabling a deliberately disabled integration in
        // production.
        const active = pick(o, "active", pick(b, "active", v.vbool(true)));
        const start = pick(o, "start", pick(b, "start", v.vstr("eager")));
        const ord = pick(o, "order", pick(b, "order", null));

        // Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
        const layers = v.vlist();
        const nm = ref.refname(r);
        for ([_]?*v.Value{ v.get(basedef, nm), b, v.get(overdef, nm), o }) |src| {
            if (v.isMap(src) and v.has(src, "options")) v.push(layers, v.get(src, "options"));
        }

        const ent = v.vmap();
        v.set(ent, "pos", v.vnum(@floatFromInt(i)));
        v.set(ent, "active", active);
        v.set(ent, "start", start);
        v.set(ent, "optionlayers", layers);
        if (ord != null) v.set(ent, "order", ord);
        v.set(instance, r, ent);
    }

    // `default` DECLARES NOTHING (§9.3). It is a base for every instance
    // of that definition; it does not create one, and an entry for a
    // name with no instances is inert rather than an error — which is
    // what makes a shared library of defaults shippable.
    const defout = v.vmap();
    for (v.keys(basedef)) |k| v.set(defout, k, v.get(basedef, k));
    for (v.keys(overdef)) |k| v.set(defout, k, v.get(overdef, k));

    const out = v.vmap();
    v.set(out, "instance", instance);
    v.set(out, "order", order);
    v.set(out, "default", defout);
    return out;
}

// ---------------------------------------------------------------------
// resolveoptions — §9.3's ten levels, and §9.4's merge directives
// ---------------------------------------------------------------------

/// §9.4: N is an integer of at least 1, and everything else is an error.
///
/// `{"deep": 0}` is rejected DESPITE having an obvious reading, because
/// "replace at this key" already has a spelling and two spellings for
/// one behaviour is the defect class this repo exists to avoid. Without
/// the stated domain each port picks its own reading — reject, replace,
/// unlimited merge, or clamp to 1 — and the same document resolves
/// differently per language.
pub fn checkshape(shape: ?*v.Value) t.Err!void {
    if (!v.isMap(shape)) return;
    for (v.keys(shape)) |k| {
        const x = v.get(shape, k);
        if (!v.isMap(x) or !v.has(x, "$MERGE")) continue;
        const d = v.get(x, "$MERGE");

        if (v.isStr(d)) {
            const w = v.asStr(d);
            if (std.mem.eql(u8, w, "replace") or std.mem.eql(u8, w, "append")) continue;
            return t.fail("plugin_shape_invalid", v.print("invalid $MERGE directive at {s}: {s}", .{ k, w }), t.details2("key", v.vstr(k), "directive", d));
        }

        if (v.isMap(d) and v.has(d, "deep")) {
            const nv = v.get(d, "deep");
            const x2 = v.asNum(nv);
            if (!v.isNum(nv) or x2 != @trunc(x2) or x2 < 1) {
                return t.fail("plugin_shape_invalid", v.print("invalid $MERGE deep at {s}: {s}", .{ k, v.json(nv) }), t.details2("key", v.vstr(k), "directive", d));
            }
            continue;
        }

        return t.fail("plugin_shape_invalid", v.print("invalid $MERGE directive at {s}: {s}", .{ k, v.json(d) }), t.details2("key", v.vstr(k), "directive", d));
    }
}

/// The shape's non-directive values are the level-1 defaults.
fn defaultsof(shape: ?*v.Value) *v.Value {
    const out = v.vmap();
    if (!v.isMap(shape)) return out;
    for (v.keys(shape)) |k| {
        const x = v.get(shape, k);
        if (v.isMap(x) and v.has(x, "$MERGE")) continue;
        v.set(out, k, x);
    }
    return out;
}

fn optsof(src: ?*v.Value, key: []const u8) t.Err!?*v.Value {
    if (v.isNull(src)) return null;
    // The array form is equivalent to the map form (§9.1).
    if (v.isList(src)) {
        for (v.items(src)) |item| {
            if (std.mem.eql(u8, try ref.canonref(v.get(item, "ref")), key)) {
                return if (v.has(item, "options")) v.get(item, "options") else null;
            }
        }
        return null;
    }
    for (v.keys(src)) |k| {
        if (std.mem.eql(u8, try ref.canonrefs(k), key)) {
            const e = v.get(src, k);
            return if (v.has(e, "options")) v.get(e, "options") else null;
        }
    }
    return null;
}

/// Merge N levels below this key, replace below that.
fn deepto(base: ?*v.Value, over: ?*v.Value, n: i64) ?*v.Value {
    if (n <= 0) return v.clone(over);
    if (!v.isMap(base) or !v.isMap(over)) return v.clone(over);
    const out = v.vmap();
    for (v.keys(base)) |k| v.set(out, k, v.get(base, k));
    for (v.keys(over)) |k| v.set(out, k, deepto(v.get(out, k), v.get(over, k), n - 1));
    return out;
}

/// Merge ONE layer onto the accumulator, honouring the shape's
/// directives. The directive holds at EVERY precedence level, not only
/// between document levels — §9.4 makes it a property of the shape,
/// which does not know which layer a value arrived from.
fn mergeone(base: ?*v.Value, over: ?*v.Value, shape: ?*v.Value) ?*v.Value {
    if (v.isNull(over)) return base;
    if (!v.isMap(base) or !v.isMap(over)) return v.clone(over);

    const out = v.vmap();
    for (v.keys(base)) |k| v.set(out, k, v.get(base, k));

    for (v.keys(over)) |k| {
        const entry = if (v.isMap(shape)) v.get(shape, k) else v.vnull();
        const directive = if (v.isMap(entry)) v.get(entry, "$MERGE") else v.vnull();
        const b = v.get(out, k);
        const o = v.get(over, k);

        if (v.isStr(directive) and std.mem.eql(u8, v.asStr(directive), "replace")) {
            v.set(out, k, v.clone(o));
        } else if (v.isStr(directive) and std.mem.eql(u8, v.asStr(directive), "append")) {
            const merged = v.vlist();
            if (v.isList(b)) {
                for (v.items(b)) |x| v.push(merged, x);
            }
            if (v.isList(o)) {
                for (v.items(o)) |x| v.push(merged, x);
            } else {
                v.push(merged, o);
            }
            v.set(out, k, merged);
        } else if (v.isMap(directive) and v.has(directive, "deep")) {
            v.set(out, k, deepto(b, o, @intFromFloat(v.asNum(v.get(directive, "deep")))));
        } else if (v.isMap(b) and v.isMap(o)) {
            // Library default: deep for maps, REPLACE for lists.
            // struct.merge is element-wise by index, which for option
            // maps is nearly always wrong — ["a"] over ["x","y","z"]
            // yielding ["a","y","z"] is the defect station hit on
            // secrets.providers.
            v.set(out, k, mergeone(b, o, null));
        } else {
            v.set(out, k, v.clone(o));
        }
    }
    return out;
}

pub fn resolveoptions(input: ?*v.Value) t.Err!*v.Value {
    var shape = v.get(input, "shape");
    if (!v.isMap(shape)) shape = v.vmap();
    try checkshape(shape);

    const r = try ref.canonref(v.get(input, "ref"));
    const name = ref.refname(r);
    var doc = v.get(input, "doc");
    if (!v.isMap(doc)) doc = v.vmap();

    const profile = v.get(input, "profile");
    const overlay = if (v.isStr(profile)) v.get(v.get(doc, "profile"), v.asStr(profile)) else v.vnull();
    const overdefault = if (v.isMap(overlay)) v.get(overlay, "default") else v.vnull();
    const overinstance = if (v.isMap(overlay)) v.get(overlay, "instance") else v.vnull();

    // ONE ordered merge, lowest to highest. Levels 3-6 are not two
    // namespaces collapsed separately and composed afterwards: that
    // inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
    // SPECIFICITY, so a prod per-definition default would lose to a base
    // instance value.
    const layers = [_]?*v.Value{
        defaultsof(shape), // 1
        v.get(input, "hostdefaults"), // 2
        try optsof(v.get(doc, "default"), name), // 3
        try optsof(v.get(doc, "instance"), r), // 4
        try optsof(overdefault, name), // 5
        try optsof(overinstance, r), // 6
        v.get(input, "env"), // 7
        v.get(input, "hostoptions"), // 8
        v.get(input, "loadoptions"), // 9
        v.get(input, "patch"), // 10
    };

    var out: ?*v.Value = v.vmap();
    for (layers) |layer| {
        if (v.isNull(layer)) continue;
        out = mergeone(out, layer, shape);
    }
    return out.?;
}
