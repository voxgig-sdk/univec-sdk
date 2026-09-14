# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/env.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Environment overrides (section 9.5) - level 7 of the ladder.

One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.

  VOXGIG_PLUGIN_PROFILE            the profile name
  VOXGIG_PLUGIN_<REF>_<PATH>       one option
  VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins

THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING OTHERWISE.
Ref and path are upper-snake with `$` -> `__` and `.` -> `_`. But `_` is
legal in a name and in a tag, and the mapping folds case, so `retry$fast`
and `retry__fast` both encode to `RETRY__FAST`, as do `Retry$fast` and
`retry$Fast`.

Rather than restrict a grammar the rest of the stack already uses, the
host DETECTS THE COLLISION: it encodes every ref it holds, and a key two
refs claim is `plugin_env_ambiguous`, naming both. The affected pair stays
configurable by document and by API, just not by environment - which is
the honest trade.

Pure: a function over a string map and a ref set. The corpus tests it
without touching a real environment.
"""

import json

from .types import fail
from .ref import canon_ref, parse_ref

PREFIX = 'VOXGIG_PLUGIN_'


def encode_ref(ref):
    """`retry$fast` -> `RETRY__FAST`."""
    return ref.replace('$', '__').replace('.', '_').upper()


def apply_env(spec):
    env = (spec or {}).get('env') or {}
    refs = [canon_ref(r) for r in ((spec or {}).get('refs') or [])]
    reserved = (spec or {}).get('reserved') or []
    out = {'options': {}, 'active': [], 'inactive': []}

    # Encode every ref the host holds, and refuse a key that two of them
    # claim. Done up front so the collision is reported even when no
    # environment variable exercises it - a latent ambiguity is still an
    # ambiguity, and finding it at deploy time is the failure this exists
    # to prevent.
    byencoded = {}
    for ref in refs:
        byencoded.setdefault(encode_ref(ref), []).append(ref)
    for encoded in sorted(byencoded):
        if 1 < len(byencoded[encoded]):
            pair = sorted(byencoded[encoded])
            fail('plugin_env_ambiguous',
                 'refs collide in the environment encoding as ' + encoded +
                 ': ' + ', '.join(pair),
                 {'encoded': encoded, 'refs': pair})

    # Longest encoded ref first, so `retry$fast` wins over `retry` on
    # `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    encoded = sorted(byencoded, key=lambda e: -len(e))

    for key in sorted(env):
        if not key.startswith(PREFIX):
            continue
        rest = key[len(PREFIX):]

        if 'PROFILE' == rest:
            out['profile'] = env[key]
            continue

        if 'ACTIVE' == rest or 'INACTIVE' == rest:
            for raw in split(env[key]):
                ref = canon_ref(raw)
                # The reservation covers EVERY input layer (section 9.1).
                # VOXGIG_PLUGIN_INACTIVE=station is easier to set than
                # editing a config file, and INACTIVE has the final word -
                # so guarding documents alone would leave the one lever
                # this mechanism exists to deny wide open.
                checkreserved(ref, reserved)
                out['active' if 'ACTIVE' == rest else 'inactive'].append(ref)
            continue

        found = None
        for enc in encoded:
            if rest == enc or rest.startswith(enc + '_'):
                found = enc
                break
        if None is found:
            continue                     # not for any ref this host holds
        ref = byencoded[found][0]
        checkreserved(ref, reserved)

        if rest == found:
            continue                     # a ref with no path sets nothing
        path = rest[len(found) + 1:].lower().split('_')

        node = out['options'].get(ref)
        if not isinstance(node, dict):
            node = {}
            out['options'][ref] = node
        for step in path[:-1]:
            child = node.get(step)
            if not isinstance(child, dict):
                child = {}
                node[step] = child
            node = child
        node[path[-1]] = parsevalue(env[key])

    return out


def split(value):
    return [s.strip() for s in str(value).split(',') if 0 < len(s.strip())]


def checkreserved(ref, reserved):
    if 0 == len(reserved):
        return
    if parse_ref(ref)['name'] in reserved:
        fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref,
             {'ref': ref})


def parsevalue(value):
    """Values parse as JSON, FALLING BACK TO STRING - so `8080` is a
    number, `true` is a boolean, `{"a":1}` is a map, and `hello` is the
    string it looks like rather than a parse error.

    `parse_constant` REFUSES PYTHON'S JSON EXTENSIONS. `json.loads`
    accepts `NaN`, `Infinity` and `-Infinity`, which are not JSON and
    which `JSON.parse` rejects - so an environment variable spelled
    `NaN` became a float here and stayed the string `'NaN'` in every
    other port. The model has one answer per input; this is not the
    place Python gets to be more generous."""
    try:
        return json.loads(value, parse_constant=_notjson)
    except Exception:
        return value


def _notjson(name):
    raise ValueError('not JSON: ' + name)
