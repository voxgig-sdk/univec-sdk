# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/sekreto.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# sekreto: one interface for secrets, wherever they live.
#
# A Sekreto is an ordered chain of providers. `get` asks each in turn and
# returns the first hit, so an app can be configured from environment
# variables in development and a vault in production without changing a
# line of its own code.
#
# A port of typescript/src/Sekreto.ts, which is canonical.
#
# THE CORE IMPORTS NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR
# SIGNS A REQUEST. The four built-in kinds - env, memory, dotenv, file -
# read at most a local file; every other kind is a voxgig/plugin
# definition under plugins/, and a chain may name one only if the calling
# project handed it in through `plugins`. See
# docs/design/plugin-providers.md.

import json
import re
import types

from ..voxgig_plugin import check_tag, format_ref, make_catalog, make_host


class SekretoError(Exception):
    """Anything sekreto refuses to do: a bad name, a missing secret, a
    provider that could not be reached."""


# `\z`-style anchors, not `$`. In Python, PCRE, Perl and .NET `$` also
# matches BEFORE a final newline, so `api.token\n` was accepted here while the
# canonical port rejected it - and `envkey` then produced the key
# `API_TOKEN\n`, sending this port looking for a differently named file and
# variable than the others.
NAMEPART = re.compile(r'\A[a-z0-9_]+\Z')


def writejson(value):
    """JSON text for a value that LEAVES the process.

    Two defaults have to be turned off. `ensure_ascii` escapes every
    non-ASCII character as \\uXXXX, and `separators` otherwise puts a space
    after each comma and colon. Neither is wrong, and both made python one
    of only three ports whose bytes differed: the rest emit a secret's
    accented or non-Latin characters as the UTF-8 they already are. The
    writer's output is part of what the ports agree on - the CLI line is
    compared byte for byte across all of them - so python matches the
    rest.

    Use this for a request body, a returned secret, the CLI's line. A
    `json.dumps` whose text is parsed again without ever being emitted
    needs no such care.
    """
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def validname(name):
    """Is this a well-formed secret name?"""
    if not isinstance(name, str) or 0 == len(name):
        return False

    for part in name.split('.'):
        if not NAMEPART.match(part):
            return False

    return True


def checkname(name):
    if not validname(name):
        raise SekretoError('sekreto: invalid name: ' + ('' if name is None else str(name)))
    return name


def envkey(name, prefix=None):
    """The environment-variable key for a name: `api.token` -> `API_TOKEN`."""
    checkname(name)
    return (prefix or '') + '_'.join(name.split('.')).upper()


def vaultref(name):
    """Where a name lives in a KV vault: `api.token` -> `api` / `token`.

    A single-segment name has no path of its own, so it becomes a secret of
    that name with the conventional field `value`.
    """
    checkname(name)

    parts = name.split('.')

    if 1 == len(parts):
        return {'path': parts[0], 'field': 'value'}

    return {'path': '/'.join(parts[:-1]), 'field': parts[-1]}


def flatname(name, sep):
    """A name flattened to one segment: `api.token` -> `api_token` (GCP
    Secret Manager, `_`) or `api-token` (Azure Key Vault, `-`).

    Those stores have no path hierarchy and reject dots in ids, so the
    dots become the store's conventional separator. With `-` as the
    separator, underscores flatten too: Azure Key Vault's alphabet is
    letters, digits and hyphens only, and a valid sekreto name like
    `with_underscore` must still be representable there. (The resulting
    `.`/`_` collision mirrors the documented envkey behaviour, where
    both already map to `_`.)
    """
    checkname(name)
    flat = sep.join(name.split('.'))
    return '-'.join(flat.split('_')) if '-' == sep else flat


def awsparam(name, prefix=None):
    """The AWS SSM Parameter Store name for a name: dots become the path
    hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
    `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
    """
    checkname(name)

    base = prefix or ''
    if '' != base and not base.startswith('/'):
        base = '/' + base
    if base.endswith('/'):
        base = base[:-1]

    return base + '/' + '/'.join(name.split('.'))


def parsedotenv(text):
    """Parse `.env` text into a map of raw keys to values.

    Deliberately small: `KEY=value`, optional `export`, `#` comments on
    their own line, and single- or double-quoted values (double quotes also
    unescape `\\n`, `\\r`, `\\t` and `\\\\`). A line with no `=` is skipped.
    """
    out = {}

    if not isinstance(text, str):
        return out

    for rawline in text.split('\n'):
        line = rawline[:-1].strip() if rawline.endswith('\r') else rawline.strip()

        if 0 == len(line) or line.startswith('#'):
            continue

        body = line[7:].strip() if line.startswith('export ') else line

        eq = body.find('=')
        if 0 >= eq:
            continue

        key = body[:eq].strip()
        value = body[eq + 1:].strip()

        if 2 <= len(value) and value.startswith('"') and value.endswith('"'):
            value = _unescape(value[1:-1])
        elif 2 <= len(value) and value.startswith("'") and value.endswith("'"):
            value = value[1:-1]

        out[key] = value

    return out


def _unescape(text):
    out = ''
    index = 0

    while index < len(text):
        if '\\' == text[index] and index + 1 < len(text):
            nxt = text[index + 1]
            index += 2
            if 'n' == nxt:
                out += '\n'
            elif 'r' == nxt:
                out += '\r'
            elif 't' == nxt:
                out += '\t'
            elif '\\' == nxt:
                out += '\\'
            elif '"' == nxt:
                out += '"'
            else:
                out += '\\' + nxt
        else:
            out += text[index]
            index += 1

    return out


def redact(text, values):
    """Replace known secret values in text with `[redacted]`.

    Only values of four characters or more are replaced: shorter ones are
    too likely to appear in ordinary text, and redacting them would make
    logs unreadable without making them safer.
    """
    out = text if isinstance(text, str) else ''

    usable = [
        value for value in (values or [])
        if isinstance(value, str) and 4 <= len(value)
    ]

    # sorted() returns a new list: `values` belongs to the caller (it is
    # `seen` when called through Sekreto.redact), and sorting in place
    # would reorder it.
    for value in sorted(usable, key=len, reverse=True):
        out = '[redacted]'.join(out.split(value))

    return out


def storename(provider):
    """The store name a live provider answers to.

    `describe()` opens with the provider's kind - `hashicorp:...`,
    `dotenv:...`, plain `env` - so the kind is the natural default, and a
    custom provider gets a sensible name without implementing anything
    extra. A spec'd provider's store is its `name` or its `kind`, decided
    before the provider exists.
    """
    return provider.describe().split(':')[0]


def _definition(plugin):
    """A plugin entry, checked to be a definition before the catalog sees it.

    Every plugin module is named after the definition it holds, so `from
    voxgig_sekreto.plugins import hashicorp` hands back the MODULE, and a
    module in the catalog would fail deep inside voxgig/plugin with a
    message about a definition name. Refused here instead, naming the
    import that was meant.
    """
    if isinstance(plugin, types.ModuleType):
        name = plugin.__name__.rsplit('.', 1)[-1]
        raise SekretoError(
            'sekreto: not a plugin definition: the module ' + plugin.__name__
            + ' - import the definition it holds: from ' + plugin.__name__
            + ' import ' + name)
    if not isinstance(plugin, dict):
        raise SekretoError('sekreto: not a plugin definition: ' + repr(plugin))
    return plugin


def _unknownkind(kind, catalog):
    """The message for a kind the catalog does not hold.

    A kind sekreto has never heard of is a typo; a kind that exists as a
    plugin but was not passed in is the split working as designed and
    telling you what to pass. Collapsing the two was the first thing that
    made the split confusing to use.
    """
    from .providers import KINDS

    message = ('sekreto: unknown provider kind: ' + str(kind)
               + ' (available: ' + ', '.join(catalog.names()) + ')')
    if kind in KINDS['plugin']:
        message += (' - ' + str(kind)
                    + ' is a sekreto plugin, not built in: pass it in the plugins option')
    return message


def _unwrap(err):
    """A SekretoError that crossed the plugin boundary comes back out as
    itself, byte for byte. Anything else is not sekreto's to rewrite."""
    from .providers import ERROR_CODE

    details = getattr(err, 'details', None)
    if ERROR_CODE == getattr(err, 'code', None) and isinstance(details, dict) \
            and isinstance(details.get('cause'), str):
        return SekretoError(details['cause'])
    return err


class Sekreto:
    """The secrets facade: a chain of providers plus a cache.

    Two ways to read. `get` is transparent - it walks the chain and takes
    the first hit, and the caller never learns which store answered.
    `getfrom` is directed - it names the store, and only that store is
    asked.
    """

    def __init__(self, options=None):
        from .providers import BUILTINS

        opts = options or {}

        # Built-ins first, then the plugins, into one catalog: a plugin
        # that names a built-in kind replaces it, which is how a host
        # substitutes an implementation and never an accident, because the
        # four names are documented.
        #
        # `catalog` is the definitions this Sekreto can build; `host` is
        # the voxgig/plugin host every spec'd provider is an instance of.
        # Read it for introspection - `host.list()` names each store's ref
        # and status - and nothing on it advances the chain.
        self.catalog = make_catalog(BUILTINS + [_definition(p) for p in opts.get('plugins') or []])
        self.host = make_host({'catalog': self.catalog})

        # (store, provider) pairs, in chain order. A provider handed in
        # live is backed by no instance; a spec'd one is an instance of
        # its kind on the host.
        self.entries = []
        for entry in opts.get('providers') or []:
            if callable(getattr(entry, 'lookup', None)):
                self.entries.append((storename(entry), entry))
            else:
                self.entries.append(self._declare(entry))

        self.docache = False is not opts.get('cache', True)

        # A list, not a dict: the store a value came from stays attached,
        # and redaction order does not vary between runs.
        self.cache = []

        # Every value ever resolved, for redact(). Kept independently of
        # the read cache so that redaction still works when cache is off -
        # otherwise `cache: False` would silently disable redact() and leak
        # secrets to logs.
        self.seen = []

    def _declare(self, spec):
        """One chain entry, as a plugin instance.

        The instance is `kind` for a store named after its kind and
        `kind$store` otherwise - `hashicorp$prod` - so `host.list()` reads
        like the chain. A store name that is already taken gets a numbered
        tag from the host instead, because two providers MAY share a store
        name (a directed read walks both) and an instance ref may not.
        """
        from .providers import PROVIDER_EXPORT

        kind = spec.get('kind') if isinstance(spec, dict) else None

        if kind is None or not self.catalog.has(kind):
            raise SekretoError(_unknownkind(kind, self.catalog))

        store = spec.get('name') or kind

        if not check_tag(store):
            raise SekretoError('sekreto: invalid store name: ' + str(store))

        ref = kind if store == kind else format_ref(kind, store)
        if self.host.instance(ref) is not None:
            ref = self.host.autotag(kind)

        try:
            # `load` runs the definition's `define`, which builds the
            # provider from the spec; `activate` takes the instance live.
            # Nothing is contacted by either: a provider opens nothing
            # until its first lookup.
            self.host.load(ref, {'options': spec})
            self.host.activate(ref)
        except Exception as err:
            raise _unwrap(err) from None

        return (store, self.host.exports(ref + '/' + PROVIDER_EXPORT))

    def get(self, name):
        """The secret, or a SekretoError if no provider has it."""
        found = self.try_(name)

        if found is None:
            raise SekretoError('sekreto: unknown secret: ' + name)

        return found

    def try_(self, name):
        """The secret, or None if no provider has it."""
        return self._resolve('', name, self.entries)

    def getfrom(self, store, name):
        """The secret from one named store, or a SekretoError if that store
        does not have it."""
        found = self.tryfrom(store, name)

        if found is None:
            raise SekretoError('sekreto: unknown secret: ' + store + ':' + name)

        return found

    def tryfrom(self, store, name):
        """The secret from one named store, or None if that store does not
        have it.

        Naming a store that is not in the chain is an error, not a miss:
        `try` already means "this store may not have it", so it cannot also
        mean "this store may not exist" without hiding a typo.
        """
        matching = [entry for entry in self.entries if entry[0] == store]

        if 0 == len(matching):
            raise SekretoError('sekreto: unknown store: ' + store)

        return self._resolve(store, name, matching)

    def _resolve(self, store, name, entries):
        checkname(name)

        if self.docache:
            for cached in self.cache:
                if cached[0] == store and cached[1] == name:
                    return cached[2]

        for _storename, provider in entries:
            found = provider.lookup(name)

            if found is not None:
                if self.docache:
                    self.cache.append((store, name, found))
                self.seen.append(found)
                return found

        return None

    def has(self, name):
        """Does any provider have this secret?"""
        return self.try_(name) is not None

    def hasin(self, store, name):
        """Does this named store have this secret?"""
        return self.tryfrom(store, name) is not None

    def all(self, names):
        """Every named secret at once. Missing ones are an error."""
        return {name: self.get(name) for name in names}

    def sources(self):
        """A description of each provider, in resolution order."""
        return [provider.describe() for _store, provider in self.entries]

    def stores(self):
        """The name of each store that can be named by `getfrom`, in
        resolution order and without repeats."""
        out = []

        for store, _provider in self.entries:
            if store not in out:
                out.append(store)

        return out

    def redact(self, text):
        """Replace every value this Sekreto has resolved with `[redacted]`.

        Works whether or not caching is enabled: the redaction list is kept
        independently of the read cache.
        """
        return redact(text, self.seen)

    def refresh(self):
        """Drop cached values, so the next `get` asks the providers again."""
        self.cache.clear()

    def close(self):
        """Tear the chain down: every plugin instance is deactivated and
        unloaded, in reverse, releasing whatever a provider acquired at
        activation. Afterwards there is nothing to read from - `get`
        reports every secret unknown - and the cache is dropped, though
        `redact` still knows every value that was ever resolved."""
        self.host.close()
        self.entries = []
        self.cache.clear()


def sekreto(options=None):
    """Make a Sekreto from options."""
    return Sekreto(options)
