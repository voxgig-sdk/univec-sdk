import { ProviderSpec, Provider } from '../provider/support';
/** HashiCorp Vault.
 *
 * KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api`
 * and takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
 * `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means
 * "not here" - a miss - so a vault can sit in a chain with fallbacks.
 *
 * A Vault Enterprise namespace rides the X-Vault-Namespace header, on
 * logins as well as reads.
 *
 * Instead of being handed a token, the provider can log in: Kubernetes
 * auth (the pod's service-account JWT, from its conventional path) or
 * AppRole. A failed login is an error, never a miss - it means this
 * store could not answer at all. */
export declare function hashicorpprovider(addr: string, token: string, options?: {
    mount?: string;
    kv?: number;
    vaultnamespace?: string;
    auth?: ProviderSpec['auth'];
}): Provider;
/** The plugin. Needs HTTPS, and the filesystem for a kubernetes JWT. */
export declare const hashicorp: import("../provider/support").Definition;
