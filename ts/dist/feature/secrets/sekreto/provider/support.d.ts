import type { Definition } from '../../plugin';
import { SekretoError, awsparam, checkname, envkey, flatname, parsedotenv, vaultref } from '../Sekreto';
declare function nodemod<T = any>(name: string): T;
export type Provider = {
    lookup: (name: string) => Promise<string | undefined> | string | undefined;
    describe: () => string;
};
/** The declarative form of a provider, as used in config and in the
 * shared spec. `kind` names a built-in or a plugin; the rest is that
 * kind's own configuration, and a plugin reads it as `inst.options`. */
export type ProviderSpec = {
    kind: string;
    name?: string;
    prefix?: string;
    file?: string;
    values?: Record<string, string>;
    dir?: string;
    addr?: string;
    token?: string;
    mount?: string;
    kv?: number;
    vaultnamespace?: string;
    /** hashicorp: log in for a token instead of being handed one. */
    auth?: {
        method: 'kubernetes' | 'approle';
        mount?: string;
        role?: string;
        jwt?: string;
        jwtfile?: string;
        roleid?: string;
        secretid?: string;
    };
    command?: string;
    profile?: string;
    backend?: string;
    reason?: string;
    namespace?: string;
    home?: string;
    region?: string;
    keyid?: string;
    secret?: string;
    session?: string;
    project?: string;
    vault?: string;
    tenant?: string;
    clientid?: string;
    clientsecret?: string;
    /** azure: where to log in / where IMDS answers. gcp: where the
     * metadata server answers. Overridable for tests and for clouds with
     * nonstandard endpoints. */
    loginaddr?: string;
    imdsaddr?: string;
    metadataaddr?: string;
    apiversion?: string;
    config?: string;
    environment?: string;
    path?: string;
    passphrase?: string;
    /** minivault: which key in the vault file to open with, defaulting to
     * `master`. Named apart from `key` and `keyid` because those already
     * mean a secret name and an AWS access key id. */
    vaultkey?: string;
    iterations?: number;
    create?: boolean;
};
/** The export key under which a provider definition publishes the
 * provider it built. `Sekreto` reads `<ref>/provider` off the host. */
export declare const PROVIDER_EXPORT = "provider";
export declare const ERROR_CODE = "sekreto_error";
export declare function providerplugin(kind: string, make: (spec: ProviderSpec) => Provider): Definition;
export { SekretoError, awsparam, checkname, envkey, flatname, parsedotenv, vaultref, };
export { nodemod };
export type { Definition };
export declare function unbase64(text: string): string | undefined;
