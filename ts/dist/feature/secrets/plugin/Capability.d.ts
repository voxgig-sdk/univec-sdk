export type Provided = {
    name: string;
    version?: string;
    priority?: number;
    attrs?: {
        [k: string]: any;
    };
};
export type Required = {
    name: string;
    range?: string;
    match?: {
        [k: string]: any;
    };
    optional?: boolean;
    /** §11.3: `static` restarts the consumer when its SELECTED provider
     * leaves, even though another still matches; `dynamic` says in
     * writing that it can survive the swap. Static is the default because
     * most plugins cannot, and the cost of wrongly assuming they can is a
     * live instance holding a dead reference. */
    policy?: 'static' | 'dynamic';
};
export type Candidate = {
    ref: string;
    pos: number;
    provides: Provided;
};
export declare function resolvecapability(req: Required, candidates: Candidate[]): Candidate[];
export declare function matches(req: Required, prov: Provided): boolean;
export declare function matchvalue(want: any, got: any): boolean;
