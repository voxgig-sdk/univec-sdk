"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/index.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
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