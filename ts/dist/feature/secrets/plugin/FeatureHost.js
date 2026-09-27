"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/FeatureHost.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.REQUEST_POINT = exports.STATION_HOOKS = exports.SDK_HOOKS = void 0;
exports.featurepoints = featurepoints;
exports.featuredefinition = featuredefinition;
exports.SDK_HOOKS = [
    'PostConstruct',
    'PostConstructEntity',
    'SetData',
    'GetData',
    'GetMatch',
    'PreTarget',
    'PreSpec',
    'PreRequest',
    'PreResponse',
    'PreResult',
    'PostOperation',
];
exports.STATION_HOOKS = ['PrePoint', 'PreDone', 'PreUnexpected'];
exports.REQUEST_POINT = 'request';
function featurepoints(fetcher, options) {
    const opts = options || {};
    const points = {};
    for (const h of exports.SDK_HOOKS.concat(exports.STATION_HOOKS).concat(opts.hooks || [])) {
        if (undefined === points[h]) {
            points[h] = { kind: 'hook' };
        }
    }
    for (const r of opts.replace || []) {
        points[r] = { kind: 'provider' };
    }
    points[exports.REQUEST_POINT] = { kind: 'chain', base: fetcher };
    return points;
}
function makectx(base, captured, options) {
    const source = (base && base.utility) || {};
    const utility = {};
    for (const k of Object.keys(source)) {
        utility[k] = source[k];
    }
    Object.defineProperty(utility, 'fetcher', {
        enumerable: true,
        configurable: true,
        get: () => captured.inner,
        set: (fn) => { captured.wrap = fn; },
    });
    return { ...base, utility, options };
}
function featuredefinition(name, Feature, options) {
    const opts = options || {};
    const seams = opts.replace || [];
    // DEDUPLICATED. A caller naming a hook the core set already has —
    // easy to do, since `extra` is "what this SDK's features declare" and
    // a feature may well declare a core one — would otherwise bind the
    // same method twice and fire it twice on one `emit`.
    const hooknames = [];
    for (const h of exports.SDK_HOOKS.concat(exports.STATION_HOOKS).concat(opts.hooks || [])) {
        if (-1 === hooknames.indexOf(h) && -1 === seams.indexOf(h)) {
            hooknames.push(h);
        }
    }
    return {
        name,
        define: (inst) => {
            const feature = new Feature();
            if (null != feature.name && feature.name !== name) {
                const err = new Error('plugin/plugin_definition_name: feature name does not match the ' +
                    'definition it was registered as: ' + feature.name + ' vs ' + name);
                err.code = 'plugin_definition_name';
                throw err;
            }
            const captured = { inner: undefined };
            let current = null;
            captured.inner = (...args) => null == current ? undefined : current(...args);
            const ctx = makectx({ client: inst, ...(opts.ctx || {}), feature }, captured, inst.options);
            if ('function' === typeof feature.init) {
                feature.init(ctx, inst.options);
            }
            for (const h of hooknames) {
                if ('function' !== typeof feature[h]) {
                    continue;
                }
                inst.bind(h, (...args) => feature[h](...args));
            }
            for (const r of seams) {
                if ('function' !== typeof feature[r]) {
                    continue;
                }
                inst.bind(r, (...args) => feature[r](...args));
            }
            // ...and the transport wrap, if the feature took one, is a chain
            // binding. THIS IS THE REVERSIBILITY: sdkgen assigns the slot and
            // can never put it back; a binding comes out when the instance
            // deactivates, with no cooperation from the feature.
            if ('function' === typeof captured.wrap) {
                inst.bind(exports.REQUEST_POINT, (next, ...args) => {
                    current = next;
                    return captured.wrap(...args);
                });
            }
            inst.export('feature', feature);
            if (null != feature.version) {
                inst.export('version', feature.version);
            }
            inst.state.feature = feature;
        },
        activate: (inst) => {
            const feature = inst && featureof(inst);
            if (feature && 'function' === typeof feature.activate) {
                feature.activate();
            }
        },
        deactivate: (inst) => {
            const feature = inst && featureof(inst);
            if (feature && 'function' === typeof feature.deactivate) {
                feature.deactivate();
            }
        },
        close: (inst) => {
            const feature = inst && featureof(inst);
            if (feature && 'function' === typeof feature.close) {
                feature.close();
            }
        },
    };
}
function featureof(inst) {
    return inst.state && inst.state.feature;
}
//# sourceMappingURL=FeatureHost.js.map