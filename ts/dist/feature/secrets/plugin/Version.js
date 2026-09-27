"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Version.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.parserange = parserange;
exports.parseversion = parseversion;
exports.satisfies = satisfies;
exports.cmp = cmp;
const Types_1 = require("./Types");
const VERSION_RE = /^(\d+)(?:\.(\d+))?(?:\.(\d+))?$/;
const COMPONENT_MAX = 2147483647;
function parserange(range) {
    if ('string' !== typeof range || 0 === range.length) {
        (0, Types_1.fail)('plugin_bad_range', 'invalid range: ' + range, { range });
    }
    const tilde = range.startsWith('~');
    const body = tilde ? range.substring(1) : range;
    const m = VERSION_RE.exec(body);
    if (!m)
        (0, Types_1.fail)('plugin_bad_range', 'invalid range: ' + range, { range });
    const major = component(m[1], range, 'range');
    const minor = undefined === m[2] ? 0 : component(m[2], range, 'range');
    const patch = undefined === m[3] ? 0 : component(m[3], range, 'range');
    const lo = [major, minor, patch];
    const hi = tilde ? [major, minor + 1, 0] : [major + 1, 0, 0];
    return { lo, hi };
}
function parseversion(version) {
    if ('string' !== typeof version) {
        (0, Types_1.fail)('plugin_bad_range', 'invalid version: ' + version, { version });
    }
    const m = VERSION_RE.exec(version);
    if (!m)
        (0, Types_1.fail)('plugin_bad_range', 'invalid version: ' + version, { version });
    return [
        component(m[1], version, 'version'),
        undefined === m[2] ? 0 : component(m[2], version, 'version'),
        undefined === m[3] ? 0 : component(m[3], version, 'version'),
    ];
}
function component(digits, whole, field) {
    const n = Number(digits);
    if (!Number.isInteger(n) || COMPONENT_MAX < n) {
        (0, Types_1.fail)('plugin_bad_range', 'version component out of range in ' + whole + ': ' + digits, { [field]: whole });
    }
    return n;
}
/** The one satisfaction predicate: lo <= version < hi. */
function satisfies(version, range) {
    const v = parseversion(version);
    const r = parserange(range);
    return 0 <= cmp(v, r.lo) && 0 > cmp(v, r.hi);
}
function cmp(a, b) {
    for (let i = 0; i < 3; i++) {
        if (a[i] !== b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}
//# sourceMappingURL=Version.js.map