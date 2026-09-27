"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/boru.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.boru = void 0;
exports.boruprovider = boruprovider;
const support_1 = require("../provider/support");
const addr_1 = require("../provider/addr");
const httpjson_1 = require("./httpjson");
function boruprovider(options) {
    const opts = options || {};
    const command = opts.command || 'boru';
    if (opts.addr) {
        const addr = opts.addr.replace(/\/$/, '');
        const mount = opts.mount || 'secret';
        return {
            lookup: async (name) => {
                (0, support_1.checkname)(name);
                (0, addr_1.checkaddr)(addr);
                const alias = opts.namespace ? opts.namespace + '/' + name : name;
                const url = addr + '/v1/' + mount + '/data/' + alias;
                const res = await (0, httpjson_1.fetchjson)('GET', url, { 'X-Vault-Token': opts.token || '' });
                if (404 === res.status) {
                    return undefined;
                }
                if (200 !== res.status) {
                    throw new support_1.SekretoError('sekreto: boru serve error: ' + res.status + ': ' + url);
                }
                const data = res.body && res.body.data && res.body.data.data;
                const value = data ? data['value'] : undefined;
                return undefined === value || null === value ? undefined : String(value);
            },
            describe: () => 'boru:' + addr,
        };
    }
    return {
        lookup: (name) => {
            (0, support_1.checkname)(name);
            const alias = opts.namespace ? opts.namespace + ':' + name : name;
            const env = opts.home ? { ...process.env, BORU_HOME: opts.home } : process.env;
            const { spawnSync } = (0, support_1.nodemod)('node:child_process');
            const run = spawnSync(command, ['vault', 'get', '--reveal', alias], {
                encoding: 'utf8',
                env,
            });
            if (run.error) {
                throw new support_1.SekretoError('sekreto: cannot run ' + command + ': ' + run.error.message);
            }
            if (0 === run.status) {
                // boru prints the value and one newline, and nothing else.
                return run.stdout.replace(/\n$/, '');
            }
            const why = (run.stderr || '').trim();
            // "no alias named" is boru saying it does not hold this secret, which
            // is a miss: the chain carries on to the next provider. A locked vault
            // or a wrong passphrase is not a miss - treating it as one would fall
            // through to a weaker store without saying so.
            if (borumiss(why)) {
                return undefined;
            }
            throw new support_1.SekretoError('sekreto: boru vault error: ' + (why || 'exit ' + run.status));
        },
        describe: () => 'boru' + (opts.namespace ? ':' + opts.namespace : ''),
    };
}
function borumiss(why) {
    return /no alias named/.test(why);
}
/** The plugin. Needs a child process (CLI mode) or HTTPS (wire mode). */
exports.boru = (0, support_1.providerplugin)('boru', (spec) => boruprovider({
    command: spec.command,
    namespace: spec.namespace,
    home: spec.home,
    addr: spec.addr,
    token: spec.token,
    mount: spec.mount,
}));
//# sourceMappingURL=boru.js.map