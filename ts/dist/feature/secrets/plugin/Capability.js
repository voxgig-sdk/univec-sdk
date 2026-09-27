"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Capability.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.resolvecapability = resolvecapability;
exports.matches = matches;
exports.matchvalue = matchvalue;
const Version_1 = require("./Version");
function resolvecapability(req, candidates) {
    const hits = candidates.filter((c) => matches(req, c.provides));
    hits.sort((a, b) => {
        const av = a.provides.version, bv = b.provides.version;
        if (av !== bv) {
            if (undefined === av)
                return 1;
            if (undefined === bv)
                return -1;
            const c = compare(bv, av); // highest version FIRST
            if (0 !== c)
                return c;
        }
        const ap = a.provides.priority || 0;
        const bp = b.provides.priority || 0;
        if (ap !== bp)
            return ap - bp; // lowest priority first
        return a.pos - b.pos;
    });
    return hits;
}
function matches(req, prov) {
    if (req.name !== prov.name)
        return false;
    if (undefined !== req.range) {
        if (undefined === prov.version)
            return false;
        if (!(0, Version_1.satisfies)(prov.version, req.range))
            return false;
    }
    if (undefined !== req.match) {
        const attrs = prov.attrs || {};
        for (const k of Object.keys(req.match)) {
            if (!(k in attrs))
                return false;
            if (!matchvalue(req.match[k], attrs[k]))
                return false;
        }
    }
    return true;
}
function matchvalue(want, got) {
    if (isMap(want)) {
        if (!isMap(got))
            return false;
        for (const k of Object.keys(want)) {
            if (!(k in got))
                return false;
            if (!matchvalue(want[k], got[k]))
                return false;
        }
        return true;
    }
    if (Array.isArray(want)) {
        if (!Array.isArray(got) || want.length !== got.length)
            return false;
        for (let i = 0; i < want.length; i++) {
            if (!matchvalue(want[i], got[i]))
                return false;
        }
        return true;
    }
    return want === got;
}
function isMap(v) {
    return null != v && 'object' === typeof v && !Array.isArray(v);
}
function compare(a, b) {
    const pa = a.split('.').map(Number);
    const pb = b.split('.').map(Number);
    for (let i = 0; i < 3; i++) {
        const x = pa[i] || 0, y = pb[i] || 0;
        if (x !== y)
            return x < y ? -1 : 1;
    }
    return 0;
}
//# sourceMappingURL=Capability.js.map