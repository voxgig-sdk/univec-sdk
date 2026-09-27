export declare function safeaddr(addr: string): string;
export declare function checkaddr(addr: string): void;
/** How long any single vault round-trip may take before it is treated as
 * unreachable. Ports carry the same bound. */
/** One JSON round-trip. Network failure is always an error - an
 * unreachable store is a store that could not answer. */
