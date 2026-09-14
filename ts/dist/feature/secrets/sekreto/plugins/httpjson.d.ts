/** One JSON round-trip. Network failure is always an error - an
 * unreachable store is a store that could not answer.
 *
 * Shared by every plugin that speaks HTTP, and by nothing in the core:
 * a chain of built-ins never reaches this file. */
export declare function fetchjson(method: string, url: string, headers: Record<string, string>, body?: string): Promise<{
    status: number;
    body: any;
}>;
