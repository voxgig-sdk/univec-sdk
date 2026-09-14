"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/dotenv.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.dotenvprovider = dotenvprovider;
const support_1 = require("./support");
/** A `.env` file, read once, keyed exactly like the environment. */
function dotenvprovider(file, prefix) {
    let values;
    const load = () => {
        if (undefined === values) {
            try {
                const { readFileSync } = (0, support_1.nodemod)('node:fs');
                values = (0, support_1.parsedotenv)(readFileSync(file, 'utf8'));
            }
            catch (err) {
                // An absent file - or an absent directory - means "no secrets
                // here", exactly like fileprovider. Anything else (permission
                // denied, an unreadable mount) is a store that could not answer,
                // and swallowing it would fall through to a weaker store.
                if ('ENOENT' === err.code || 'ENOTDIR' === err.code) {
                    values = {};
                }
                else {
                    throw new support_1.SekretoError('sekreto: dotenv provider cannot read ' + file + ': ' + err.message);
                }
            }
        }
        return values;
    };
    return {
        lookup: (name) => load()[(0, support_1.envkey)(name, prefix)],
        describe: () => 'dotenv:' + file,
    };
}
//# sourceMappingURL=dotenv.js.map