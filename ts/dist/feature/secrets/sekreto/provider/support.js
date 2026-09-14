"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/support.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// What a provider is, what its declarative form looks like, and how a
// provider kind becomes a voxgig/plugin definition.
//
// A provider answers one question: "do you have this secret?" It returns
// the value, or undefined to mean "ask the next one". Nothing else about
// a provider is visible to the caller - which is the point: an app reads
// `api.token` and never learns whether it came from the environment, a
// .env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.
//
// Two failure shapes, and they are never interchangeable. A store that
// does not hold the secret is a MISS (undefined) - the chain carries on.
// A store that could not answer - bad credentials, unreachable host,
// missing configuration - is an ERROR: falling through there would
// quietly reach for a weaker store.
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
// NODE BUILTINS, LOADED ON FIRST USE.
//
// `fs` and `path` are what the two built-in file-reading providers need,
// and they are loaded when a lookup runs rather than when sekreto is
// imported: a caller who only ever configures `memory` or `env` never
// evaluates them, and a runtime that lacks them fails at the point of
// use rather than at import. The platform-dependent providers proper -
// everything that opens a socket or spawns a process - are not in the
// core at all; they are plugins (docs/design/plugin-providers.md).
//
// A plain require(), not `await import()`: dotenvprovider and
// fileprovider have SYNCHRONOUS lookups, and making them async to
// accommodate a dynamic import would change observable behaviour for
// anyone calling a provider directly. The package is CommonJS ("type":
// "commonjs"), so require is available and synchronous.
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
// --- providers as voxgig/plugin definitions --------------------------
/** The export key under which a provider definition publishes the
 * provider it built. `Sekreto` reads `<ref>/provider` off the host. */
exports.PROVIDER_EXPORT = 'provider';
/** The voxgig/plugin error code a SekretoError travels under when it is
 * raised inside a definition's `define`.
 *
 * plugin wraps a code-less error raised by a callback as
 * `plugin_define_failed`, and keeps an error that already carries a
 * code. A provider that refuses its own configuration - `kv: 3`, a
 * missing project - raises a SekretoError, and that message is pinned
 * by the spec byte for byte, so it must come back out of the host
 * exactly as it went in. `providerplugin` gives it this code on the way
 * in; `Sekreto` turns it back into a SekretoError on the way out. */
exports.ERROR_CODE = 'sekreto_error';
/** A provider kind, as a voxgig/plugin definition.
 *
 * This is the whole bridge between the two libraries. The definition's
 * `name` is the `kind` a ProviderSpec names; its `define` reads the spec
 * as `inst.options`, builds the provider with `make`, and exports it.
 * Nothing runs at `activate`: a provider opens nothing until its first
 * lookup, so there is nothing to capture - a provider that does hold a
 * resource acquires it there and lets the instance scope unwind it.
 *
 * Every built-in and every plugin is made this way, so a custom
 * provider kind is one call:
 *
 *     providerplugin('mystore', (spec) => mystoreprovider(spec.addr))
 */
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
/** Decode standard base64, or undefined when the text is not base64.
 *
 * `Buffer.from(text, 'base64')` is lenient: it skips anything outside the
 * alphabet and hands back whatever it managed, so a corrupted payload
 * became a plausible-looking string of bytes that the caller then returned
 * AS THE SECRET. The alphabet is checked first so that a store which
 * answered incoherently can be told apart from one that answered.
 *
 * A store that could not answer coherently is an ERROR, never a miss — the
 * same rule this code already applies to a 200 whose body is not JSON. */
function unbase64(text) {
    const trimmed = text.replace(/\s+/g, '');
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(trimmed) || 0 !== trimmed.length % 4) {
        return undefined;
    }
    return Buffer.from(trimmed, 'base64').toString('utf8');
}
//# sourceMappingURL=support.js.map