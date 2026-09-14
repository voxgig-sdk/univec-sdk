import { Definition } from './Catalog';
import { PointSpec } from './Host';
/** sdkgen's declared hook vocabulary (`main.kit.feature.&.hook` in
 * `model/sdkgen.aon`).
 *
 * §17.2 says "13 hook points, named exactly as today". The model
 * declares ELEVEN; the three station's own feature adds — `PrePoint`,
 * `PreDone`, `PreUnexpected` — are declared by that feature rather than
 * by the core, because `hook: &:` admits any name. So the count depends
 * on which features are installed, which is why the bridge takes the
 * extra names rather than this list pretending to be closed.
 * Recorded in doc/plan/handover.md rather than silently resolved. */
export declare const SDK_HOOKS: string[];
/** The hooks sdkgen-station's feature declares beyond the core set.
 * Named here so the bridge's default vocabulary covers the one feature
 * this repo's first consumer actually ships. */
export declare const STATION_HOOKS: string[];
/** The one chain point: the SDK's transport. Its base is
 * `utility.fetcher`, which is exactly what a wrapping feature captures
 * and replaces today. */
export declare const REQUEST_POINT = "request";
/** What a particular SDK adds to the default vocabulary.
 *
 * All three fields exist because §17.2's mapping is stated in terms of
 * a specific SDK's declarations, and a bridge that hard-coded them
 * would be right for exactly one SDK. */
export type BridgeOptions = {
    /** Hook names this SDK's installed features declare beyond the core
     * set. */
    hooks?: string[];
    /** §17.2: "`provider` points for the seams `__replace__` currently
     * serves." A replacement seam is a PROVIDER point and not a chain —
     * at most one implementation wins, the losers are visible, and the
     * host keeps a default — which is precisely what `__replace__` means
     * and what a chain cannot express. */
    replace?: string[];
    /** The SDK's REAL ctx. A feature's `init` may read `ctx.client`,
     * `ctx.utility.log` or anything else the SDK hands it, and a
     * synthetic object with one property would either give it the wrong
     * client or fail on a missing utility. The bridge layers its
     * `fetcher` trap ON TOP of this rather than replacing it. */
    ctx?: any;
};
/** Points for a bridge host: every hook name as a `hook` point, each
 * replacement seam as a `provider` point, plus `request` as a `chain`
 * whose base is the SDK's own fetcher. */
export declare function featurepoints(fetcher: (...args: any[]) => any, options?: BridgeOptions): {
    [point: string]: PointSpec;
};
export type FeatureClass = {
    new (...args: any[]): any;
};
/** Turn an sdkgen `Feature` class into a plugin definition, MECHANICALLY
 * (§17.2):
 *
 *  - `name` and `version` come off the instance, as today;
 *  - `init(ctx, options)` runs in `define`, where reading options and
 *    declaring bindings belong;
 *  - a method named after a hook point IS a binding to that point —
 *    "a feature's method names are its bindings";
 *  - a method named after a replacement seam is a `provider` binding;
 *  - an assignment to `ctx.utility.fetcher` becomes a `request` chain
 *    binding rather than an irreversible overwrite.
 *
 * The feature class is not modified, subclassed or inspected beyond its
 * own public surface. That is the claim being proved.
 *
 *
 * WHAT "AND DEACTIVATES IT" CLAIMS, EXACTLY.
 *
 * §17.2 says `init` "splits into `define` (read options, declare
 * bindings) and `activate` (capture)". THAT SPLIT IS SDKGEN'S TO MAKE.
 * An unmodified feature has one `init` and no teardown method, so the
 * bridge runs `init` in `define` and there is nothing it could call to
 * undo a side effect `init` performed — a connection opened there stays
 * open, and no amount of bridging changes that.
 *
 * So the claim is precisely: THE FEATURE'S BINDINGS BECOME REVERSIBLE.
 * Its hooks stop firing and its transport wrap leaves the chain, with
 * no cooperation from the feature — which is the thing sdkgen cannot do
 * at all, because it assigns the slot and has nowhere to put the old
 * value back. It is not a claim that arbitrary `init` side effects are
 * undone.
 *
 * A feature that DOES carry `activate` / `deactivate` / `close` methods
 * gets them wired below, which is the same mapping applied to the
 * methods §17.2 expects an adopting sdkgen to add. */
export declare function featuredefinition(name: string, Feature: FeatureClass, options?: BridgeOptions): Definition;
