"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/env.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.envprovider = envprovider;
const support_1 = require("./support");
/** Environment variables: `api.token` from `API_TOKEN`. */
function envprovider(prefix, source) {
    const env = source || process.env;
    return {
        lookup: (name) => {
            const value = env[(0, support_1.envkey)(name, prefix)];
            return undefined === value || null === value ? undefined : String(value);
        },
        describe: () => 'env' + (prefix ? ':' + prefix : ''),
    };
}
//# sourceMappingURL=env.js.map