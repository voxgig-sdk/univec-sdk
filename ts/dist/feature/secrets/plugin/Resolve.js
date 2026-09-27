"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Resolve.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.resolvecandidates = resolvecandidates;
exports.resolvefrom = resolvefrom;
function resolvecandidates(name, sources) {
    const out = [];
    // A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
    // already a package id; prefixing it produces
    // `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    if (name.startsWith('@'))
        return [name];
    const list = sources && 0 < sources.length ? sources : DEFAULT_SOURCES;
    for (const src of list) {
        if ('module' === src.kind) {
            const prefixes = src.prefix && 0 < src.prefix.length ? src.prefix : [''];
            for (const p of prefixes) {
                const id = p + name;
                if (-1 === out.indexOf(id))
                    out.push(id);
            }
        }
        else if ('path' === src.kind) {
            const id = src.dir.replace(/\/+$/, '') + '/' + name;
            if (-1 === out.indexOf(id))
                out.push(id);
        }
    }
    return out;
}
const DEFAULT_SOURCES = [
    { kind: 'module', prefix: ['@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', ''] },
];
function resolvefrom(from) {
    return [from];
}
//# sourceMappingURL=Resolve.js.map