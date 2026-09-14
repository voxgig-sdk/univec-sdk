"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/boru.ts)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.boru = void 0;
exports.boruprovider = boruprovider;
const support_1 = require("../provider/support");
const addr_1 = require("../provider/addr");
const httpjson_1 = require("./httpjson");
/** A boru vault (https://github.com/boru-lang/boru).
 *
 * Two ways in, both boru's own.
 *
 * With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
 * secret on stdout and nothing else. The passphrase is read by boru
 * itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as
 * config and never puts it on a command line, where it would show up in
 * the process table.
 *
 * With an `addr`, boru's wire protocol: `boru vault serve` publishes a
 * read-only, HashiCorp-shaped provision API (boru's
 * design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
 * from `boru vault grant`. A sekreto name is already a valid boru
 * alias, and boru aliases keep their dots, so `api.token` is the single
 * path segment `api.token` - not the `api`/`token` split a HashiCorp KV
 * gets. The value is the `value` field. A 404 is a miss; anything else
 * the server refuses (a revoked capability, a sealed vault) is an
 * error.
 *
 * boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
 * credential *broker*, built precisely so the caller never receives the
 * credential. `vault serve` is the provision endpoint, built to hand
 * the value back - that is the one sekreto uses. */
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
/** Does this boru failure mean "no such secret" rather than "I could not
 * answer"? Matched on boru's own wording for a missing alias. */
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