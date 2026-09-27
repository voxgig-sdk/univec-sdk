"use strict";
// VENDORED: @voxgig/plugin 0.1.6 (typescript/src/Ref.ts)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.checkname = checkname;
exports.checktag = checktag;
exports.parseref = parseref;
exports.formatref = formatref;
exports.canonref = canonref;
exports.tryref = tryref;
const Types_1 = require("./Types");
/** §4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024. */
const NAME_RE = /^[a-zA-Z@][a-zA-Z0-9.~_\-\/]*$/;
const TAG_RE = /^[a-zA-Z0-9.~_-]+$/;
const MAX = 1024;
function checkname(name) {
    if ('string' !== typeof name)
        return false;
    if (0 === name.length || MAX < name.length)
        return false;
    return NAME_RE.test(name);
}
function checktag(tag) {
    if ('string' !== typeof tag)
        return false;
    // The empty tag is an ordinary tag (§4 rule 2). The single-instance
    // case writes no tag and never learns tags exist.
    if (0 === tag.length)
        return true;
    if (MAX < tag.length)
        return false;
    return TAG_RE.test(tag);
}
function parseref(str) {
    if ('string' !== typeof str) {
        (0, Types_1.fail)('plugin_bad_name', 'ref must be a string');
    }
    const cut = str.indexOf('$');
    const name = -1 === cut ? str : str.substring(0, cut);
    const tag = -1 === cut ? '' : str.substring(cut + 1);
    if (!checkname(name)) {
        (0, Types_1.fail)('plugin_bad_name', 'invalid plugin name: ' + name, { name });
    }
    if (!checktag(tag)) {
        (0, Types_1.fail)('plugin_bad_tag', 'invalid plugin tag: ' + tag, { name, tag });
    }
    return { name, tag };
}
function formatref(name, tag) {
    const t = null == tag ? '' : tag;
    if (!checkname(name)) {
        (0, Types_1.fail)('plugin_bad_name', 'invalid plugin name: ' + name, { name });
    }
    if (!checktag(t)) {
        (0, Types_1.fail)('plugin_bad_tag', 'invalid plugin tag: ' + t, { name, tag: t });
    }
    return '' === t ? name : name + '$' + t;
}
/** The canonical spelling of a ref. §4 rule 5: ports must canonicalize
 * before comparison. */
function canonref(str) {
    const r = parseref(str);
    return formatref(r.name, r.tag);
}
function tryref(str) {
    if ('string' !== typeof str)
        return undefined;
    const cut = str.indexOf('$');
    const name = -1 === cut ? str : str.substring(0, cut);
    const tag = -1 === cut ? '' : str.substring(cut + 1);
    if (!checkname(name) || !checktag(tag))
        return undefined;
    return '' === tag ? name : name + '$' + tag;
}
//# sourceMappingURL=Ref.js.map