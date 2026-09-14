import { Provider } from './support';
/** Literal values, keyed like environment variables. The spec uses this
 * to test chain behaviour without touching the outside world, and an app
 * uses it for defaults. */
export declare function memoryprovider(values: Record<string, string>, prefix?: string): Provider;
