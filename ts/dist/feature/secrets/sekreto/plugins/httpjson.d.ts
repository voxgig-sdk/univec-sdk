export declare function fetchjson(method: string, url: string, headers: Record<string, string>, body?: string): Promise<{
    status: number;
    body: any;
}>;
