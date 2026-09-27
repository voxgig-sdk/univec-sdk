"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/src/Sekreto.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
Object.defineProperty(exports, "__esModule", { value: true });
exports.Sekreto = exports.SekretoError = void 0;
exports.validname = validname;
exports.checkname = checkname;
exports.envkey = envkey;
exports.vaultref = vaultref;
exports.flatname = flatname;
exports.awsparam = awsparam;
exports.parsedotenv = parsedotenv;
exports.redact = redact;
exports.sekreto = sekreto;
const plugin_1 = require("../plugin");
const support_1 = require("./provider/support");
const builtin_1 = require("./provider/builtin");
class SekretoError extends Error {
    constructor(message) {
        super(message);
        this.name = 'SekretoError';
    }
}
exports.SekretoError = SekretoError;
const NAMEPART = /^[a-z0-9_]+$/;
function validname(name) {
    if ('string' !== typeof name || 0 === name.length) {
        return false;
    }
    const parts = name.split('.');
    for (const part of parts) {
        if (!NAMEPART.test(part)) {
            return false;
        }
    }
    return true;
}
function checkname(name) {
    if (!validname(name)) {
        throw new SekretoError('sekreto: invalid name: ' + String(null == name ? '' : name));
    }
    return name;
}
function envkey(name, prefix) {
    checkname(name);
    return (prefix || '') + name.split('.').join('_').toUpperCase();
}
/** Where a name lives in a KV vault: `api.token` -> `api` / `token`.
 *
 * A single-segment name has no path of its own, so it becomes a secret of
 * that name with the conventional field `value`. */
function vaultref(name) {
    checkname(name);
    const parts = name.split('.');
    if (1 === parts.length) {
        return { path: parts[0], field: 'value' };
    }
    return { path: parts.slice(0, -1).join('/'), field: parts[parts.length - 1] };
}
function flatname(name, sep) {
    checkname(name);
    const flat = name.split('.').join(sep);
    return '-' === sep ? flat.split('_').join('-') : flat;
}
/** The AWS SSM Parameter Store name for a name: dots become the path
 * hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
 * `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`. */
function awsparam(name, prefix) {
    checkname(name);
    let base = prefix || '';
    if ('' !== base && !base.startsWith('/')) {
        base = '/' + base;
    }
    base = base.replace(/\/$/, '');
    return base + '/' + name.split('.').join('/');
}
function parsedotenv(text) {
    const out = {};
    if ('string' !== typeof text) {
        return out;
    }
    for (const rawline of text.split('\n')) {
        const line = rawline.replace(/\r$/, '').trim();
        if (0 === line.length || line.startsWith('#')) {
            continue;
        }
        const body = line.startsWith('export ') ? line.slice(7).trim() : line;
        const eq = body.indexOf('=');
        if (0 >= eq) {
            continue;
        }
        const key = body.slice(0, eq).trim();
        let value = body.slice(eq + 1).trim();
        if (2 <= value.length && value.startsWith('"') && value.endsWith('"')) {
            value = unescape(value.slice(1, -1));
        }
        else if (2 <= value.length && value.startsWith("'") && value.endsWith("'")) {
            value = value.slice(1, -1);
        }
        out[key] = value;
    }
    return out;
}
function unescape(text) {
    let out = '';
    for (let index = 0; index < text.length; index++) {
        if ('\\' === text[index] && index + 1 < text.length) {
            const next = text[index + 1];
            index++;
            if ('n' === next) {
                out += '\n';
            }
            else if ('r' === next) {
                out += '\r';
            }
            else if ('t' === next) {
                out += '\t';
            }
            else if ('\\' === next) {
                out += '\\';
            }
            else if ('"' === next) {
                out += '"';
            }
            else {
                out += '\\' + next;
            }
        }
        else {
            out += text[index];
        }
    }
    return out;
}
function redact(text, values) {
    let out = 'string' === typeof text ? text : '';
    const usable = (values || []).filter((value) => 'string' === typeof value && 4 <= value.length);
    for (const value of [...usable].sort((left, right) => right.length - left.length)) {
        out = out.split(value).join('[redacted]');
    }
    return out;
}
function storename(provider) {
    return provider.describe().split(':')[0];
}
function unknownkind(kind, catalog) {
    const known = -1 !== builtin_1.KINDS.plugin.indexOf(String(kind));
    return ('sekreto: unknown provider kind: ' + String(kind) +
        ' (available: ' + catalog.names().join(', ') + ')' +
        (known ? ' - ' + String(kind) + ' is a sekreto plugin, not built in: pass it in the plugins option' : ''));
}
function unwrap(err) {
    if (err && support_1.ERROR_CODE === err.code && err.details && 'string' === typeof err.details.cause) {
        return new SekretoError(err.details.cause);
    }
    return err;
}
class Sekreto {
    /** The voxgig/plugin host every spec'd provider is an instance of.
     * Read it for introspection - `host.list()` names each store's ref and
     * status - and nothing on it advances the chain. */
    host;
    catalog;
    entries;
    docache;
    cache;
    // Every value ever resolved, for redact(). Kept independently of the
    // read cache so that redaction still works when cache is off - otherwise
    // `cache: false` would silently disable redact() and leak secrets to logs.
    seen;
    constructor(options) {
        const opts = options || {};
        this.catalog = (0, plugin_1.makecatalog)(builtin_1.BUILTINS.concat(opts.plugins || []));
        this.host = (0, plugin_1.makehost)({ catalog: this.catalog });
        this.entries = (opts.providers || []).map((entry) => {
            if ('function' === typeof entry.lookup) {
                const provider = entry;
                return { store: storename(provider), ref: '', provider };
            }
            return this.declare(entry);
        });
        this.docache = false === opts.cache ? false : true;
        this.cache = [];
        this.seen = [];
    }
    declare(spec) {
        const kind = null == spec ? undefined : spec.kind;
        if (undefined === kind || !this.catalog.has(kind)) {
            throw new SekretoError(unknownkind(kind, this.catalog));
        }
        const store = spec.name || kind;
        if (!(0, plugin_1.checktag)(store)) {
            throw new SekretoError('sekreto: invalid store name: ' + store);
        }
        let ref = store === kind ? kind : (0, plugin_1.formatref)(kind, store);
        if (undefined !== this.host.instance(ref)) {
            ref = this.host.autotag(kind);
        }
        try {
            // `load` runs the definition's `define`, which builds the provider
            // from the spec; `activate` takes the instance live. Nothing is
            // contacted by either: a provider opens nothing until its first
            // lookup.
            this.host.load(ref, { options: spec });
            this.host.activate(ref);
        }
        catch (err) {
            throw unwrap(err);
        }
        return { store, ref, provider: this.host.exports(ref + '/' + support_1.PROVIDER_EXPORT) };
    }
    async get(name) {
        const found = await this.try(name);
        if (undefined === found) {
            throw new SekretoError('sekreto: unknown secret: ' + name);
        }
        return found;
    }
    async try(name) {
        return this.resolve('', name, this.entries);
    }
    async getfrom(store, name) {
        const found = await this.tryfrom(store, name);
        if (undefined === found) {
            throw new SekretoError('sekreto: unknown secret: ' + store + ':' + name);
        }
        return found;
    }
    async tryfrom(store, name) {
        const matching = this.entries.filter((entry) => entry.store === store);
        if (0 === matching.length) {
            throw new SekretoError('sekreto: unknown store: ' + store);
        }
        return this.resolve(store, name, matching);
    }
    async resolve(store, name, entries) {
        checkname(name);
        if (this.docache) {
            const hit = this.cache.find((entry) => entry.store === store && entry.name === name);
            if (undefined !== hit) {
                return hit.value;
            }
        }
        for (const entry of entries) {
            const found = await entry.provider.lookup(name);
            if (undefined !== found && null !== found) {
                if (this.docache) {
                    this.cache.push({ store, name, value: found });
                }
                this.seen.push(found);
                return found;
            }
        }
        return undefined;
    }
    async has(name) {
        return undefined !== (await this.try(name));
    }
    async hasin(store, name) {
        return undefined !== (await this.tryfrom(store, name));
    }
    async all(names) {
        const out = {};
        for (const name of names) {
            out[name] = await this.get(name);
        }
        return out;
    }
    toJSON() {
        return { stores: this.stores() };
    }
    [Symbol.for('nodejs.util.inspect.custom')]() {
        return 'Sekreto { stores: [ ' + this.stores().join(', ') + ' ] }';
    }
    sources() {
        return this.entries.map((entry) => entry.provider.describe());
    }
    stores() {
        const out = [];
        for (const entry of this.entries) {
            if (!out.includes(entry.store)) {
                out.push(entry.store);
            }
        }
        return out;
    }
    redact(text) {
        return redact(text, this.seen);
    }
    refresh() {
        this.cache = [];
    }
    /** Tear the chain down: every plugin instance is deactivated and
     * unloaded, in reverse, releasing whatever a provider acquired at
     * activation. Afterwards there is nothing to read from - `get` reports
     * every secret unknown - and the cache is dropped, though `redact`
     * still knows every value that was ever resolved. */
    close() {
        this.host.close();
        this.entries = [];
        this.cache = [];
    }
}
exports.Sekreto = Sekreto;
function sekreto(options) {
    return new Sekreto(options);
}
//# sourceMappingURL=Sekreto.js.map