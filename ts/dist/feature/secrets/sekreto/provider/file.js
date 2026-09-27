"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/file.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.fileprovider = fileprovider;
const support_1 = require("./support");
function fileprovider(dir, prefix) {
    return {
        lookup: (name) => {
            const { join } = (0, support_1.nodemod)('node:path');
            const file = join(dir, (0, support_1.envkey)(name, prefix));
            let text;
            try {
                const { readFileSync } = (0, support_1.nodemod)('node:fs');
                text = readFileSync(file, 'utf8');
            }
            catch (err) {
                // An absent file - or an absent directory - means "no secrets
                // here", exactly like a missing .env. Anything else (permission
                // denied, an unreadable mount) is a store that could not answer.
                if ('ENOENT' === err.code || 'ENOTDIR' === err.code) {
                    return undefined;
                }
                throw new support_1.SekretoError('sekreto: file provider cannot read ' + file + ': ' + err.message);
            }
            return text.replace(/\r?\n$/, '');
        },
        describe: () => 'file:' + dir,
    };
}
//# sourceMappingURL=file.js.map