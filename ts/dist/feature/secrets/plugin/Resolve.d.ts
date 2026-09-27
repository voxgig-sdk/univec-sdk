export type Source = {
    kind: 'module';
    prefix?: string[];
} | {
    kind: 'path';
    dir: string;
};
export declare function resolvecandidates(name: string, sources?: Source[]): string[];
export declare function resolvefrom(from: string): string[];
