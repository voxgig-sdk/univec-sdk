export type Source = {
    kind: 'module';
    prefix?: string[];
} | {
    kind: 'path';
    dir: string;
};
export declare function resolvecandidates(name: string, sources?: Source[]): string[];
/** A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name
 * with a letter or `@`, so `./local/thing` is not a ref and never
 * reaches candidate generation — seneca allows a path where a plugin
 * name goes, and this design deliberately does not, because a ref is an
 * ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
 *
 * Loading from an explicit location is a separate field that bypasses
 * candidate generation entirely: `from` is passed to the resolver
 * verbatim, and a resolver that cannot honour a location raises
 * plugin_resolve_failed. */
export declare function resolvefrom(from: string): string[];
