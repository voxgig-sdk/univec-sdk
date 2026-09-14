"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/builtin.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.KINDS = exports.BUILTINS = void 0;
// THE BUILT-IN PROVIDER KINDS - the same four in every port.
//
// What makes a kind built in is that it needs nothing of the platform
// beyond reading a local file: no socket, no TLS, no crypto, no child
// process. These four are the floor every chain stands on, and a chain
// that reads secrets from options, the environment, a plaintext `.env`
// and a mounted secret directory works with no plugin loaded at all.
// Everything else - the vault clients, the cloud stores, the CLIs - is a
// plugin, and lives under `plugins/` (docs/design/plugin-providers.md).
const support_1 = require("./support");
const env_1 = require("./env");
const memory_1 = require("./memory");
const dotenv_1 = require("./dotenv");
const file_1 = require("./file");
exports.BUILTINS = [
    (0, support_1.providerplugin)('env', (spec) => (0, env_1.envprovider)(spec.prefix)),
    (0, support_1.providerplugin)('memory', (spec) => (0, memory_1.memoryprovider)(spec.values || {}, spec.prefix)),
    (0, support_1.providerplugin)('dotenv', (spec) => (0, dotenv_1.dotenvprovider)(spec.file || '.env', spec.prefix)),
    (0, support_1.providerplugin)('file', (spec) => (0, file_1.fileprovider)(spec.dir || '', spec.prefix)),
];
/** Every kind this library ships, built in or as a plugin, so that an
 * unknown kind can be told from a plugin that was not loaded. */
exports.KINDS = {
    builtin: ['env', 'memory', 'dotenv', 'file'],
    plugin: [
        'hashicorp', 'boru', 'awssecrets', 'awsparams', 'gcpsecrets',
        'azuresecrets', 'onepassword', 'doppler', 'infisical', 'secretspec',
    ],
};
//# sourceMappingURL=builtin.js.map