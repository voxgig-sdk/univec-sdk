"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/provider/builtin.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.KINDS = exports.BUILTINS = void 0;
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
        'minivault',
    ],
};
//# sourceMappingURL=builtin.js.map