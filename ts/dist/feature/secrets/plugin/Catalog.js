"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Catalog.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* The definition catalog (§10.1).
 *
 * A definition is registered once and may back many instances. Option
 * shapes are validated AT REGISTRATION, not when a document happens to
 * exercise a key — so a malformed shape fails once, and in the same
 * place everywhere (§9.4). */
Object.defineProperty(exports, "__esModule", { value: true });
exports.makecatalog = makecatalog;
const Types_1 = require("./Types");
const Ref_1 = require("./Ref");
const Config_1 = require("./Config");
function makecatalog(defs) {
    const map = {};
    const add = (def) => {
        if (!def || !(0, Ref_1.checkname)(def.name)) {
            (0, Types_1.fail)('plugin_definition_name', 'invalid definition name: ' + (def && def.name));
        }
        // Validate the shape HERE. Deferring it to resolution time means a
        // malformed shape surfaces at a different moment in every host that
        // loads it, which is the divergence the stated domain exists to
        // prevent.
        if (def.shape)
            (0, Config_1.checkshape)(def.shape);
        map[def.name] = def;
    };
    for (const d of defs || [])
        add(d);
    return {
        add,
        get: (name) => map[name],
        has: (name) => undefined !== map[name],
        names: () => Object.keys(map).sort(),
    };
}
//# sourceMappingURL=Catalog.js.map