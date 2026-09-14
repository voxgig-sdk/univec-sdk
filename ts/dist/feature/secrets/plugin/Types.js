"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Types.ts)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Shared types. Deliberately small: the design's §19 budget says the
 * library owns naming, configuration, lifecycle, ordering, binding and
 * teardown, and nothing else. */
Object.defineProperty(exports, "__esModule", { value: true });
exports.PluginError = exports.DETAIL_ORDER = void 0;
exports.formaterror = formaterror;
exports.fail = fail;
/** §12's detail fields, IN THIS FIXED ORDER.
 *
 * The order is part of the contract, not a formatting preference. An
 * earlier draft named six fields while other sections promised
 * diagnostics that had nowhere to go, which would have left each port
 * inventing its own order and breaking message parity. */
exports.DETAIL_ORDER = [
    'host', 'ref', 'name', 'tag', 'point', 'key', 'capability',
    'range', 'version', 'match', 'candidates', 'cycle', 'holders',
    'refs', 'path', 'cause',
];
/** `plugin/<code>: <text> [<key>=<value> …]`
 *
 * Values render as COMPACT JSON, so a value containing a space or a
 * bracket cannot break the parse, and a list renders as a JSON array.
 * The bracket is absent entirely when no field applies. */
function formaterror(code, text, details) {
    const d = details || {};
    const parts = [];
    for (const k of exports.DETAIL_ORDER) {
        if (undefined === d[k])
            continue;
        parts.push(k + '=' + JSON.stringify(d[k]));
    }
    const tail = 0 === parts.length ? '' : ' [' + parts.join(' ') + ']';
    return 'plugin/' + code + ': ' + text + tail;
}
/** Every error carries a §12 code. Ports compare by CODE and never by
 * message: wording is a port's own business, and pinning the words
 * would make every translation a corpus change. The FORMAT, however, is
 * pinned — a parseable message is what makes a log searchable across
 * twenty languages. */
class PluginError extends Error {
    code;
    text;
    details;
    constructor(code, text, details) {
        super(formaterror(code, text, details));
        this.name = 'PluginError';
        this.code = code;
        this.text = text;
        this.details = details || {};
    }
}
exports.PluginError = PluginError;
function fail(code, text, details) {
    throw new PluginError(code, text, details);
}
//# sourceMappingURL=Types.js.map