# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/version.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Versions and ranges (section 11.2).

TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a concrete
version. A requirement declares `range`. A requirement is satisfied when
the names match, the `match` passes, and:

  the provider's `version` falls inside the requirement's `range`.

That is the whole rule. There is no third field and no second comparison -
an earlier draft added a provider-side `compat` range, which left three
values and no statement of how they combine, and three defensible
readings of one declaration is worse than the ambiguity it was introduced
to fix.
"""

import re

from .types import fail

# `\Z`, NOT `$` — the same trap as the ref grammar. Python's `$` also
# matches before a trailing newline, so `^...$` accepts "2.1\n" as a
# range. Pinned by `version/rangebad#trailing-newline`.
VERSION_RE = re.compile(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?\Z')

# A COMPONENT IS BOUNDED, and the bound is the model's, not the host
# language's. Python integers are unbounded and JavaScript's stop being
# exact past 2^53, so `4294967296.0.0` compared as an ordinary number in
# one port and lost precision in another. 2^31-1 is the smallest bound
# every target language holds exactly, which makes it the model's.
COMPONENT_MAX = 2147483647


def component(digits, whole, field):
    value = int(digits)
    if COMPONENT_MAX < value:
        fail('plugin_bad_range',
             'version component out of range in ' + whole + ': ' + digits,
             {field: whole})
    return value


def parse_range(text):
    """Two forms and no more (section 11.2):

      '2.1'    >= 2.1.0 and < 3.0.0
      '~2.1'   >= 2.1.0 and < 2.2.0
    """
    if not isinstance(text, str) or 0 == len(text):
        fail('plugin_bad_range', 'invalid range: ' + str(text),
             {'range': text})

    tilde = text.startswith('~')
    body = text[1:] if tilde else text
    found = VERSION_RE.match(body)
    if None is found:
        fail('plugin_bad_range', 'invalid range: ' + text, {'range': text})

    major = component(found.group(1), text, 'range')
    minor = (0 if None is found.group(2)
             else component(found.group(2), text, 'range'))
    patch = (0 if None is found.group(3)
             else component(found.group(3), text, 'range'))

    lo = [major, minor, patch]
    hi = [major, minor + 1, 0] if tilde else [major + 1, 0, 0]
    return {'lo': lo, 'hi': hi}


def parse_version(text):
    if not isinstance(text, str):
        fail('plugin_bad_range', 'invalid version: ' + str(text),
             {'version': text})
    found = VERSION_RE.match(text)
    if None is found:
        fail('plugin_bad_range', 'invalid version: ' + text,
             {'version': text})
    return [
        component(found.group(1), text, 'version'),
        (0 if None is found.group(2)
         else component(found.group(2), text, 'version')),
        (0 if None is found.group(3)
         else component(found.group(3), text, 'version')),
    ]


def satisfies(version, text):
    """The one satisfaction predicate: lo <= version < hi."""
    value = parse_version(version)
    span = parse_range(text)
    return 0 <= cmp(value, span['lo']) and 0 > cmp(value, span['hi'])


def satisfiesq(version, text):
    """satisfies for the internal callers that treat an unparseable
    version or range as "does not satisfy" - Capability and Graph, both of
    which run over data the corpus has already admitted."""
    try:
        return satisfies(version, text)
    except Exception:
        return False


def cmp(a, b):
    for i in range(3):
        x = a[i] if i < len(a) else 0
        y = b[i] if i < len(b) else 0
        if x != y:
            return -1 if x < y else 1
    return 0
