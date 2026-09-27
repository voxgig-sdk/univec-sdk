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
    selected: {
        [name: string]: string;
    };
    barred?: boolean;
    unmet: string[];
    /** Resources the instance scope holds, newest last — unwound in
     * REVERSE, because that is the only order in which teardown mirrors
     * setup (§8.3). */
    scope: (() => void)[];
    /** Declared in `define`, inserted only when activation SUCCEEDS
     * (§8.1). Holding them until then is what makes a failed activate
     * leave nothing behind. */
    bindings: Bound[];
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
