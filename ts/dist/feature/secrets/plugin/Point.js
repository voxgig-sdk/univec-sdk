"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Point.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.emit = emit;
exports.compose = compose;
exports.provider = provider;
const Types_1 = require("./Types");
/** Fan-out. Return values are ignored except in `bail`. */
function emit(bindings, mode, arg) {
    if ('bail' === mode) {
        for (const b of bindings) {
            const v = b.fn(arg);
            if (null != v)
                return v;
        }
        return undefined;
    }
    const errors = [];
    for (const b of bindings) {
        try {
            b.fn(arg);
        }
        catch (err) {
            // `emit` raises synchronously; the collecting modes gather.
            if ('emit' === mode)
                throw err;
            errors.push(err);
        }
    }
    return 'emit' === mode ? undefined : errors;
}
function compose(bindings, base) {
    let next = base;
    for (let i = bindings.length - 1; 0 <= i; i--) {
        const fn = bindings[i].fn;
        const inner = next;
        next = (...args) => fn(inner, ...args);
    }
    return next;
}
function provider(bindings, spec) {
    if (0 === bindings.length)
        return { shadowed: [] };
    if (spec.exclusive && 1 < bindings.length) {
        const refs = bindings.map((b) => b.ref).sort();
        (0, Types_1.fail)('plugin_point_exclusive', 'point is exclusive and has ' + bindings.length + ' bindings: ' + refs.join(', '), { refs });
    }
    const ranked = bindings.slice().sort((a, b) => {
        if (a.band !== b.band)
            return b.band - a.band;
        return a.ref < b.ref ? -1 : a.ref > b.ref ? 1 : 0;
    });
    return { winner: ranked[0], shadowed: ranked.slice(1).map((b) => b.ref) };
}
//# sourceMappingURL=Point.js.map