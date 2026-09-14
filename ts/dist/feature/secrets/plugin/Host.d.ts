import { Status, OrderBlock } from './Types';
import { Catalog, Definition } from './Catalog';
import { Spec, Bound } from './Point';
import { Provided } from './Capability';
export type PointSpec = Spec;
export type HostOptions = {
    catalog?: Catalog;
    reserved?: string[];
    keys?: {
        instance?: string;
        default?: string;
    };
    defaults?: {
        [name: string]: any;
    };
    profile?: string;
    points?: {
        [point: string]: PointSpec;
    };
    /** §11.3. `restart` (the default) treats provider replacement as an
     * ordinary runtime operation: deactivate the old store, activate the
     * new one, and everything that depended on it rides through, having
     * released the old one's resources in between.
     *
     * `hold` is the strict reading — deactivating a required instance is
     * `plugin_dependency_held`, naming the holders. NOT the default,
     * because a station that cannot swap a provider without a restart
     * has lost the argument for having a plugin system. */
    dependency?: 'restart' | 'hold';
};
type Live = {
    ref: string;
    def: Definition;
    status: Status;
    pos: number;
    seq: number;
    options: any;
    state: any;
    order?: OrderBlock;
    /** §11.4's ALWAYS-RELUCTANT rebinding, made concrete: the provider
     * ref this instance's activation actually selected, per requirement
     * name. "A satisfied requirement is not re-bound while it stays
     * satisfied" is a statement about a REMEMBERED choice — recomputing
     * `providersof(r)[0]` on every question silently re-points a live
     * consumer at any better-ranked newcomer, and then losing the
     * provider it was really using does not restart it. Captured at
     * activate, cleared on the way out. */
    selected: {
        [name: string]: string;
    };
    /** §9.6's `active: false` — "declares it and bars it: it appears in
     * `host.list()`, and `activate` and `ready` on it fail rather than
     * quietly doing nothing". THE BAR OUTLIVES THE APPLY THAT SET IT: a
     * flag consulted only while `apply` ran let a later direct `ready`
     * bring the instance live, which is the config-switch it exists to
     * be silently ignored. */
    barred?: boolean;
    /** Requirements this instance declared but has not been given. */
    unmet: string[];
    /** Resources the instance scope holds, newest last — unwound in
     * REVERSE, because that is the only order in which teardown mirrors
     * setup (§8.3). */
    scope: (() => void)[];
    /** Declared in `define`, inserted only when activation SUCCEEDS
     * (§8.1). Holding them until then is what makes a failed activate
     * leave nothing behind. */
    bindings: Bound[];
    /** Set when this instance is itself a host (§6.5). */
    inner?: any;
    /** Declared in `define`, and VISIBLE while merely `loaded` (§11):
     * they are data, and hiding them would make the loaded state useless
     * for introspection. */
    exports: {
        [key: string]: any;
    };
    provides: Provided[];
};
export type Host = ReturnType<typeof makehost>;
export declare function makehost(options?: HostOptions): {
    catalog: Catalog;
    list: () => {
        [ref: string]: Status;
    };
    instance: (ref: string) => Live | undefined;
    order: (point?: string) => string[];
    observable: (result?: any) => {
        status: {
            [ref: string]: Status;
        };
        open: number;
        log: string[];
        result: any;
    };
    hostdeclare: (ref: string, spec?: {
        definition?: string;
        options?: any;
        order?: OrderBlock;
        pos?: number;
        tag?: string;
        /** §9.1: "The host declares those instances itself, after the user
         * merge, and always wins." Set ONLY by `hostdeclare`. */
        hostowned?: boolean;
    }) => Live;
    trace: () => {
        ref: string;
        event: string;
        seq: number;
        status: Status;
    }[];
    autotag: (name: string) => string;
    positionof: (ref: string, point: string) => any;
    emit: (point: string, arg?: any) => any;
    call: (point: string, ...args: any[]) => any;
    provider: (point: string, ...args: any[]) => any;
    shadowed: (point: string) => string[];
    exports: (spec: string) => any;
    capability: (name: string) => string[];
    declare: (ref: string, spec?: {
        definition?: string;
        options?: any;
        order?: OrderBlock;
        pos?: number;
        tag?: string;
        /** §9.1: "The host declares those instances itself, after the user
         * merge, and always wins." Set ONLY by `hostdeclare`. */
        hostowned?: boolean;
    }) => Live;
    load: (ref: string, spec?: any) => Live;
    activate: (ref: string) => Live;
    deactivate: (ref: string) => Live;
    unload: (ref: string) => void;
    ready: (ref: string) => Live;
    apply: (doc: any, profile?: string) => void;
    close: () => void;
    options: (ref: string, patch: any) => void;
    define: (def: Definition) => void;
};
export {};
