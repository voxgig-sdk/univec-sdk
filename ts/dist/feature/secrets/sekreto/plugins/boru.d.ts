import { Provider } from '../provider/support';
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
export declare function boruprovider(options?: {
    command?: string;
    namespace?: string;
    home?: string;
    addr?: string;
    token?: string;
    mount?: string;
}): Provider;
/** The plugin. Needs a child process (CLI mode) or HTTPS (wire mode). */
export declare const boru: import("../provider/support").Definition;
