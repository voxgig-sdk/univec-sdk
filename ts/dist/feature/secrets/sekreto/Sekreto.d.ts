import type { Catalog, Definition, Host } from '../plugin';
import { Provider, ProviderSpec } from './provider/support';
export type Name = string;
export type SekretoOptions = {
    providers?: (Provider | ProviderSpec)[];
    /** The provider kinds beyond the built-ins that `providers` may name,
     * as voxgig/plugin definitions. Static and explicit: the calling
     * project imports the plugins it needs and passes them here, and a
     * kind it did not pass is unknown to this Sekreto. */
    plugins?: Definition[];
    cache?: boolean;
};
export declare class SekretoError extends Error {
    constructor(message: string);
}
export declare function validname(name: any): boolean;
export declare function checkname(name: any): string;
export declare function envkey(name: Name, prefix?: string): string;
/** Where a name lives in a KV vault: `api.token` -> `api` / `token`.
 *
 * A single-segment name has no path of its own, so it becomes a secret of
 * that name with the conventional field `value`. */
export declare function vaultref(name: Name): {
    path: string;
    field: string;
};
export declare function flatname(name: Name, sep: string): string;
/** The AWS SSM Parameter Store name for a name: dots become the path
 * hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
 * `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`. */
export declare function awsparam(name: Name, prefix?: string): string;
export declare function parsedotenv(text: string): Record<string, string>;
export declare function redact(text: string, values: string[]): string;
export declare class Sekreto {
    /** The voxgig/plugin host every spec'd provider is an instance of.
     * Read it for introspection - `host.list()` names each store's ref and
     * status - and nothing on it advances the chain. */
    readonly host: Host;
    readonly catalog: Catalog;
    private entries;
    private docache;
    private cache;
    private seen;
    constructor(options?: SekretoOptions);
    private declare;
    get(name: Name): Promise<string>;
    try(name: Name): Promise<string | undefined>;
    getfrom(store: string, name: Name): Promise<string>;
    tryfrom(store: string, name: Name): Promise<string | undefined>;
    private resolve;
    has(name: Name): Promise<boolean>;
    hasin(store: string, name: Name): Promise<boolean>;
    all(names: Name[]): Promise<Record<string, string>>;
    toJSON(): object;
    sources(): string[];
    stores(): string[];
    redact(text: string): string;
    refresh(): void;
    /** Tear the chain down: every plugin instance is deactivated and
     * unloaded, in reverse, releasing whatever a provider acquired at
     * activation. Afterwards there is nothing to read from - `get` reports
     * every secret unknown - and the cache is dropped, though `redact`
     * still knows every value that was ever resolved. */
    close(): void;
}
export declare function sekreto(options?: SekretoOptions): Sekreto;
