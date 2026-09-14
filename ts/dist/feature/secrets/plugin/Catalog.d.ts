export type Definition = {
    name: string;
    shape?: any;
    define?: (inst: any) => void;
    activate?: (inst: any) => void;
    deactivate?: (inst: any) => void;
    close?: (inst: any) => void;
    reconfigure?: (inst: any, options: any, previous: any) => void;
};
export type Catalog = {
    add: (def: Definition) => void;
    get: (name: string) => Definition | undefined;
    has: (name: string) => boolean;
    names: () => string[];
};
export declare function makecatalog(defs?: Definition[]): Catalog;
