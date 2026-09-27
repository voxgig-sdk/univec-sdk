import { ProviderSpec, Provider } from '../provider/support';
export declare function hashicorpprovider(addr: string, token: string, options?: {
    mount?: string;
    kv?: number;
    vaultnamespace?: string;
    auth?: ProviderSpec['auth'];
}): Provider;
/** The plugin. Needs HTTPS, and the filesystem for a kubernetes JWT. */
export declare const hashicorp: import("../provider/support").Definition;
