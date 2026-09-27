"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Graph.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.resolvegraph = resolvegraph;
const Capability_1 = require("./Capability");
const Version_1 = require("./Version");
const Ref_1 = require("./Ref");
function resolvegraph(nodes) {
    const byref = {};
    for (const n of nodes)
        byref[n.ref] = n;
    const resolved = new Set();
    const blocked = {};
    let moved = true;
    while (moved) {
        moved = false;
        for (const n of nodes) {
            if (resolved.has(n.ref))
                continue;
            const why = firstunmet(n, byref, resolved);
            if (null == why) {
                resolved.add(n.ref);
                moved = true;
            }
        }
    }
    for (const n of nodes) {
        if (resolved.has(n.ref))
            continue;
        const why = firstunmet(n, byref, resolved);
        if (null != why)
            blocked[n.ref] = why;
    }
    return {
        resolved: Array.from(resolved).sort(),
        blocked: Object.keys(blocked).sort().map((r) => blocked[r]),
    };
}
function firstunmet(n, byref, resolved) {
    for (const req of n.requires || []) {
        if (req.optional)
            continue;
        const all = candidates(byref, req.name);
        if (0 === all.length) {
            return { ref: n.ref, unmet: req.name, why: { kind: 'absent' } };
        }
        const ok = (0, Capability_1.resolvecapability)(req, all);
        if (0 < ok.length) {
            // A provider exists and matches — but if none of them is itself
            // resolved, this node is blocked BEHIND it, and the chain is the
            // useful answer rather than "unmet".
            const live = ok.filter((c) => resolved.has(c.ref));
            if (0 < live.length)
                continue;
            return {
                ref: n.ref, unmet: req.name,
                why: { kind: 'blocked', chain: ok.map((c) => c.ref).sort() },
            };
        }
        // Providers exist and none matched. Say which test failed.
        if (undefined !== req.range) {
            const versions = all
                .filter((c) => undefined === c.provides.version || !(0, Version_1.satisfies)(c.provides.version, req.range))
                .map((c) => c.provides.version || '(none)');
            if (0 < versions.length) {
                return {
                    ref: n.ref, unmet: req.name,
                    why: { kind: 'version', range: req.range, found: versions.sort() },
                };
            }
        }
        if (undefined !== req.match) {
            for (const c of all) {
                const attrs = c.provides.attrs || {};
                for (const k of Object.keys(req.match).sort()) {
                    if (!(k in attrs) || !(0, Capability_1.matchvalue)(req.match[k], attrs[k])) {
                        return {
                            ref: n.ref, unmet: req.name,
                            why: {
                                kind: 'match', failing: k,
                                want: req.match[k],
                                found: undefined === attrs[k] ? null : attrs[k],
                            },
                        };
                    }
                }
            }
        }
        return { ref: n.ref, unmet: req.name, why: { kind: 'absent' } };
    }
    return null;
}
function candidates(byref, name) {
    const out = [];
    const asref = (0, Ref_1.tryref)(name);
    for (const ref of Object.keys(byref).sort()) {
        const n = byref[ref];
        if (ref === asref) {
            out.push({ ref: n.ref, pos: n.pos, provides: { name } });
            continue;
        }
        for (const p of n.provides || []) {
            if (p.name === name)
                out.push({ ref: n.ref, pos: n.pos, provides: p });
        }
    }
    return out;
}
//# sourceMappingURL=Graph.js.map