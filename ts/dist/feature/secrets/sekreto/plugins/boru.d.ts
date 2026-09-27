import { Provider } from '../provider/support';
export declare function boruprovider(options?: {
    command?: string;
    namespace?: string;
    home?: string;
    addr?: string;
    token?: string;
    mount?: string;
}): Provider;
/** The plugin. Needs a child process (CLI mode) or HTTPS (wire mode). */
export declare const boru: import("../provider/support").Definition;
