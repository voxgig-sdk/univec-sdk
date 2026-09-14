"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/index.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// @voxgig/sekreto - one interface for secrets, wherever they live.
Object.defineProperty(exports, "__esModule", { value: true });
exports.safeaddr = exports.checkaddr = exports.ERROR_CODE = exports.PROVIDER_EXPORT = exports.providerplugin = exports.KINDS = exports.BUILTINS = exports.fileprovider = exports.dotenvprovider = exports.memoryprovider = exports.envprovider = exports.vaultref = exports.validname = exports.sekreto = exports.redact = exports.parsedotenv = exports.flatname = exports.envkey = exports.awsparam = exports.SekretoError = exports.Sekreto = void 0;
var Sekreto_1 = require("./Sekreto");
Object.defineProperty(exports, "Sekreto", { enumerable: true, get: function () { return Sekreto_1.Sekreto; } });
Object.defineProperty(exports, "SekretoError", { enumerable: true, get: function () { return Sekreto_1.SekretoError; } });
Object.defineProperty(exports, "awsparam", { enumerable: true, get: function () { return Sekreto_1.awsparam; } });
Object.defineProperty(exports, "envkey", { enumerable: true, get: function () { return Sekreto_1.envkey; } });
Object.defineProperty(exports, "flatname", { enumerable: true, get: function () { return Sekreto_1.flatname; } });
Object.defineProperty(exports, "parsedotenv", { enumerable: true, get: function () { return Sekreto_1.parsedotenv; } });
Object.defineProperty(exports, "redact", { enumerable: true, get: function () { return Sekreto_1.redact; } });
Object.defineProperty(exports, "sekreto", { enumerable: true, get: function () { return Sekreto_1.sekreto; } });
Object.defineProperty(exports, "validname", { enumerable: true, get: function () { return Sekreto_1.validname; } });
Object.defineProperty(exports, "vaultref", { enumerable: true, get: function () { return Sekreto_1.vaultref; } });
// THE CORE SURFACE: the chain, the four built-in provider kinds, and the
// means of adding a fifth.
//
// The built-ins are the kinds that read at most a local file - env,
// memory, dotenv, file. Everything that opens a socket, spawns a process
// or signs a request is a PLUGIN, is not reachable from this file, and
// is handed to `Sekreto` by the calling project:
//
//     import { Sekreto } from '@voxgig/sekreto'
//     import { hashicorp } from '@voxgig/sekreto/plugins/hashicorp'
//
//     const secrets = new Sekreto({
//       plugins: [hashicorp],
//       providers: [{ kind: 'env' }, { kind: 'hashicorp', addr, token }],
//     })
//
// or, for every kind at once, `allplugins` from '@voxgig/sekreto/plugins'.
// Re-exporting a plugin here would put AWS request signing in every
// build again, which is the thing the split removes. See
// docs/design/plugin-providers.md.
var env_1 = require("./provider/env");
Object.defineProperty(exports, "envprovider", { enumerable: true, get: function () { return env_1.envprovider; } });
var memory_1 = require("./provider/memory");
Object.defineProperty(exports, "memoryprovider", { enumerable: true, get: function () { return memory_1.memoryprovider; } });
var dotenv_1 = require("./provider/dotenv");
Object.defineProperty(exports, "dotenvprovider", { enumerable: true, get: function () { return dotenv_1.dotenvprovider; } });
var file_1 = require("./provider/file");
Object.defineProperty(exports, "fileprovider", { enumerable: true, get: function () { return file_1.fileprovider; } });
var builtin_1 = require("./provider/builtin");
Object.defineProperty(exports, "BUILTINS", { enumerable: true, get: function () { return builtin_1.BUILTINS; } });
Object.defineProperty(exports, "KINDS", { enumerable: true, get: function () { return builtin_1.KINDS; } });
// How a provider kind becomes a plugin definition - the one call a
// custom kind needs.
var support_1 = require("./provider/support");
Object.defineProperty(exports, "providerplugin", { enumerable: true, get: function () { return support_1.providerplugin; } });
Object.defineProperty(exports, "PROVIDER_EXPORT", { enumerable: true, get: function () { return support_1.PROVIDER_EXPORT; } });
Object.defineProperty(exports, "ERROR_CODE", { enumerable: true, get: function () { return support_1.ERROR_CODE; } });
// A pure validator, no platform dependency - kept on the core surface
// because callers validate an address before configuring a provider.
var addr_1 = require("./provider/addr");
Object.defineProperty(exports, "checkaddr", { enumerable: true, get: function () { return addr_1.checkaddr; } });
Object.defineProperty(exports, "safeaddr", { enumerable: true, get: function () { return addr_1.safeaddr; } });
//# sourceMappingURL=index.js.map