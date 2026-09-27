"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/memory.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.memoryprovider = memoryprovider;
const support_1 = require("./support");
/** Literal values, keyed like environment variables. The spec uses this
 * to test chain behaviour without touching the outside world, and an app
 * uses it for defaults. */
function memoryprovider(values, prefix) {
    return {
        lookup: (name) => values[(0, support_1.envkey)(name, prefix)],
        describe: () => 'memory' + (prefix ? ':' + prefix : ''),
    };
}
//# sourceMappingURL=memory.js.map