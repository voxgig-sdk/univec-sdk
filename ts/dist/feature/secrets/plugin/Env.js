"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Env.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.encoderef = encoderef;
exports.applyenv = applyenv;
const Types_1 = require("./Types");
const Ref_1 = require("./Ref");
const PREFIX = 'VOXGIG_PLUGIN_';
function encoderef(ref) {
    return ref.replace(/\$/g, '__').replace(/\./g, '_').toUpperCase();
}
function applyenv(input) {
    const env = (input && input.env) || {};
    const refs = ((input && input.refs) || []).map(Ref_1.canonref);
    const reserved = (input && input.reserved) || [];
    const out = { options: {}, active: [], inactive: [] };
    // Encode every ref the host holds, and refuse a key that two of them
    // claim. Done up front so the collision is reported even when no
    // environment variable exercises it — a latent ambiguity is still an
    // ambiguity, and finding it at deploy time is the failure this exists
    // to prevent.
    const byencoded = {};
    for (const r of refs) {
        const e = encoderef(r);
        (byencoded[e] || (byencoded[e] = [])).push(r);
    }
    for (const e of Object.keys(byencoded).sort()) {
        if (1 < byencoded[e].length) {
            const pair = byencoded[e].slice().sort();
            (0, Types_1.fail)('plugin_env_ambiguous', 'refs collide in the environment encoding as ' + e + ': ' + pair.join(', '), { encoded: e, refs: pair });
        }
    }
    const encoded = Object.keys(byencoded).sort((a, b) => b.length - a.length);
    for (const key of Object.keys(env).sort()) {
        if (!key.startsWith(PREFIX))
            continue;
        const rest = key.substring(PREFIX.length);
        if ('PROFILE' === rest) {
            out.profile = env[key];
            continue;
        }
        if ('ACTIVE' === rest || 'INACTIVE' === rest) {
            for (const r of split(env[key])) {
                const c = (0, Ref_1.canonref)(r);
                checkreserved(c, reserved);
                if ('ACTIVE' === rest)
                    out.active.push(c);
                else
                    out.inactive.push(c);
            }
            continue;
        }
        const enc = encoded.find((e) => rest === e || rest.startsWith(e + '_'));
        if (undefined === enc)
            continue; // not for any ref this host holds
        const ref = byencoded[enc][0];
        checkreserved(ref, reserved);
        if (rest === enc)
            continue; // a ref with no path sets nothing
        const path = rest.substring(enc.length + 1).toLowerCase().split('_');
        let node = out.options[ref] || (out.options[ref] = {});
        for (let i = 0; i < path.length - 1; i++) {
            node = node[path[i]] || (node[path[i]] = {});
        }
        node[path[path.length - 1]] = parsevalue(env[key]);
    }
    return out;
}
function split(v) {
    return String(v).split(',').map((s) => s.trim()).filter((s) => 0 < s.length);
}
function checkreserved(ref, reserved) {
    if (0 === reserved.length)
        return;
    if (-1 !== reserved.indexOf((0, Ref_1.parseref)(ref).name)) {
        (0, Types_1.fail)('plugin_ref_reserved', 'ref is reserved by the host: ' + ref, { ref });
    }
}
function parsevalue(v) {
    try {
        return JSON.parse(v);
    }
    catch (err) {
        return v;
    }
}
//# sourceMappingURL=Env.js.map