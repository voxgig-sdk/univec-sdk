"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Export.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.resolveexport = resolveexport;
const Types_1 = require("./Types");
const Ref_1 = require("./Ref");
function resolveexport(spec, exported) {
    const cut = spec.lastIndexOf('/');
    if (-1 === cut) {
        (0, Types_1.fail)('plugin_export_ambiguous', 'export spec needs a key: ' + spec, { spec });
    }
    const head = spec.substring(0, cut);
    const key = spec.substring(cut + 1);
    // A fully qualified ref: exactly one answer or none.
    const exact = exported.filter((e) => e.ref === (0, Ref_1.canonref)(head) && e.key === key);
    if (0 < exact.length)
        return exact[0].value;
    // An alias: the name, not a ref. Look at every instance of it.
    const byname = exported.filter((e) => (0, Ref_1.parseref)(e.ref).name === head && e.key === key);
    if (0 === byname.length)
        return undefined;
    const untagged = byname.filter((e) => '' === (0, Ref_1.parseref)(e.ref).tag);
    if (0 < untagged.length)
        return untagged[0].value;
    if (1 === byname.length)
        return byname[0].value;
    const refs = byname.map((e) => e.ref).sort();
    (0, Types_1.fail)('plugin_export_ambiguous', 'alias ' + spec + ' matches ' + refs.length + ' instances: ' + refs.join(', '), { spec, refs });
}
//# sourceMappingURL=Export.js.map