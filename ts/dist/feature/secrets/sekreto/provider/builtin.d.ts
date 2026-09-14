import { Definition } from './support';
export declare const BUILTINS: Definition[];
/** Every kind this library ships, built in or as a plugin, so that an
 * unknown kind can be told from a plugin that was not loaded. */
export declare const KINDS: {
    builtin: string[];
    plugin: string[];
};
