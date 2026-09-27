"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Depend.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.normrequire = normrequire;
exports.requirements = requirements;
exports.restartsonloss = restartsonloss;
exports.gatesactivation = gatesactivation;
exports.restartcausing = restartcausing;
exports.dependencycycle = dependencycycle;
exports.checkcycle = checkcycle;
const Ref_1 = require("./Ref");
const Types_1 = require("./Types");
/** A bare string is shorthand for `{name}`. */
function normrequire(r) {
    return ('string' === typeof r ? { name: r } : (r || {}));
}
function requirements(options) {
    const raw = (options && options.requires) || [];
    const marked = (options && options.optional) || [];
    const fallback = options && options.policy;
    return raw.map(normrequire).map((r) => {
        const out = { ...r };
        if (r.optional || -1 !== marked.indexOf(r.name)) {
            out.optional = true;
        }
        if (undefined === out.policy && undefined !== fallback) {
            out.policy = fallback;
        }
        return out;
    });
}
function restartsonloss(r) {
    return 'dynamic' !== (r.policy || 'static');
}
function gatesactivation(r) {
    return true !== r.optional;
}
function restartcausing(r) {
    return gatesactivation(r) || restartsonloss(r);
}
function dependencycycle(nodes) {
    const bycap = {};
    const isref = {};
    for (const n of nodes) {
        isref[n.ref] = true;
        for (const cap of n.provides) {
            (bycap[cap] = bycap[cap] || []).push(n.ref);
        }
    }
    const edges = {};
    for (const n of nodes) {
        const out = [];
        for (const r of n.requires) {
            if (!restartcausing(r))
                continue;
            const from = (bycap[r.name] || []).slice();
            // A node satisfies its own name AS A REF (§11.1), canonically —
            // exactly what `providersof` does at runtime, so the load-time
            // graph and the running one agree about what an edge is.
            const asref = (0, Ref_1.tryref)(r.name);
            if (undefined !== asref && isref[asref] && -1 === from.indexOf(asref)) {
                from.push(asref);
            }
            for (const p of from) {
                if (p !== n.ref && -1 === out.indexOf(p))
                    out.push(p);
            }
        }
        edges[n.ref] = out.sort();
    }
    const WHITE = 0, GREY = 1, BLACK = 2;
    const colour = {};
    for (const n of nodes)
        colour[n.ref] = WHITE;
    for (const start of Object.keys(edges).sort()) {
        if (WHITE !== colour[start])
            continue;
        const path = [];
        const stack = [{ ref: start, i: 0 }];
        colour[start] = GREY;
        path.push(start);
        while (0 < stack.length) {
            const top = stack[stack.length - 1];
            const next = edges[top.ref][top.i++];
            if (undefined === next) {
                colour[top.ref] = BLACK;
                stack.pop();
                path.pop();
                continue;
            }
            if (GREY === colour[next]) {
                // Report the cycle itself, not the walk that found it.
                return path.slice(path.indexOf(next)).concat([next]);
            }
            if (BLACK === colour[next])
                continue;
            colour[next] = GREY;
            path.push(next);
            stack.push({ ref: next, i: 0 });
        }
    }
    return null;
}
/** Raise on a cycle, naming it. Separate from the detector so the
 * detector stays pure and corpus-testable. */
function checkcycle(nodes) {
    const cycle = dependencycycle(nodes);
    if (null != cycle) {
        (0, Types_1.fail)('plugin_dependency_cycle', 'requirements cycle: ' + cycle.join(' -> '), { cycle });
    }
}
//# sourceMappingURL=Depend.js.map