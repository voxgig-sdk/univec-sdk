"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/support.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.vaultref = exports.parsedotenv = exports.flatname = exports.envkey = exports.checkname = exports.awsparam = exports.SekretoError = exports.ERROR_CODE = exports.PROVIDER_EXPORT = void 0;
exports.providerplugin = providerplugin;
exports.nodemod = nodemod;
exports.unbase64 = unbase64;
const plugin_1 = require("../../plugin");
const Sekreto_1 = require("../Sekreto");
Object.defineProperty(exports, "SekretoError", { enumerable: true, get: function () { return Sekreto_1.SekretoError; } });
Object.defineProperty(exports, "awsparam", { enumerable: true, get: function () { return Sekreto_1.awsparam; } });
Object.defineProperty(exports, "checkname", { enumerable: true, get: function () { return Sekreto_1.checkname; } });
Object.defineProperty(exports, "envkey", { enumerable: true, get: function () { return Sekreto_1.envkey; } });
Object.defineProperty(exports, "flatname", { enumerable: true, get: function () { return Sekreto_1.flatname; } });
Object.defineProperty(exports, "parsedotenv", { enumerable: true, get: function () { return Sekreto_1.parsedotenv; } });
Object.defineProperty(exports, "vaultref", { enumerable: true, get: function () { return Sekreto_1.vaultref; } });
const nodemods = {};
function nodemod(name) {
    let mod = nodemods[name];
    if (undefined === mod) {
        try {
            // eslint-disable-next-line @typescript-eslint/no-require-imports
            mod = nodemods[name] = require(name);
        }
        catch (err) {
            throw new Sekreto_1.SekretoError('sekreto: this provider needs ' +
                name +
                ', which this runtime does not provide: ' +
                err.message);
        }
    }
    return mod;
}
/** The export key under which a provider definition publishes the
 * provider it built. `Sekreto` reads `<ref>/provider` off the host. */
exports.PROVIDER_EXPORT = 'provider';
exports.ERROR_CODE = 'sekreto_error';
function providerplugin(kind, make) {
    return {
        name: kind,
        define: (inst) => {
            let provider;
            try {
                provider = make(inst.options);
            }
            catch (err) {
                if (err instanceof Sekreto_1.SekretoError) {
                    throw new plugin_1.PluginError(exports.ERROR_CODE, err.message, { ref: inst.ref, cause: err.message });
                }
                throw err;
            }
            inst.export(exports.PROVIDER_EXPORT, provider);
        },
    };
}
function unbase64(text) {
    const trimmed = text.replace(/\s+/g, '');
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(trimmed) || 0 !== trimmed.length % 4) {
        return undefined;
    }
    return Buffer.from(trimmed, 'base64').toString('utf8');
}
//# sourceMappingURL=support.js.map