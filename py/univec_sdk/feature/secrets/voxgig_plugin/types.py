# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/types.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Shared types. Deliberately small: the design's section 19 budget says
the library owns naming, configuration, lifecycle, ordering, binding and
teardown, and nothing else.

PYTHON IS THE OTHER HALF OF P4'S PROVING PAIR (section 18): "the closest
dynamic analogue that is not JavaScript". It raises where the canonical
raises and go returns, so the interesting differences here are not about
errors — they are about the places JavaScript's coercion rules and
Python's disagree, and `True == 1` is the first of them.
"""

import json


# Section 5.1's seven statuses, and no more. A port that adds an eighth is
# diverging. `loading` and `closing` are observable only from inside a
# callback or from another thread.
STATUSES = ['declared', 'loaded', 'pending', 'live', 'failed',
            'loading', 'closing']


# Section 12's detail fields, IN THIS FIXED ORDER.
#
# The order is part of the contract, not a formatting preference. An
# earlier draft named six fields while other sections promised
# diagnostics that had nowhere to go, which would have left each port
# inventing its own order and breaking message parity.
DETAIL_ORDER = [
    'host', 'ref', 'name', 'tag', 'point', 'key', 'capability',
    'range', 'version', 'match', 'candidates', 'cycle', 'holders',
    'refs', 'path', 'cause',
]


def compactjson(value):
    """JSON.stringify's output: compact, and NOT ascii-escaped.

    `ensure_ascii=True` would render a non-ASCII value as `\\uXXXX` where
    every other port prints the character, which breaks section 12
    message parity on exactly the inputs least likely to be tested.
    """
    return json.dumps(value, separators=(',', ':'), ensure_ascii=False)


def formaterror(code, text, details=None):
    """`plugin/<code>: <text> [<key>=<value> ...]`

    Values render as COMPACT JSON, so a value containing a space or a
    bracket cannot break the parse, and a list renders as a JSON array.
    The bracket is absent entirely when no field applies.
    """
    details = details or {}
    parts = []
    for key in DETAIL_ORDER:
        if key not in details:
            continue
        parts.append(key + '=' + compactjson(details[key]))
    tail = '' if 0 == len(parts) else ' [' + ' '.join(parts) + ']'
    return 'plugin/' + code + ': ' + text + tail


class PluginError(Exception):
    """Every error carries a section 12 code. Ports compare by CODE and
    never by message: wording is a port's own business, and pinning the
    words would make every translation a corpus change. The FORMAT,
    however, is pinned - a parseable message is what makes a log
    searchable across twenty languages."""

    def __init__(self, code, text, details=None):
        super().__init__(formaterror(code, text, details))
        self.code = code
        self.text = text
        self.details = details or {}


def fail(code, text, details=None):
    raise PluginError(code, text, details)


def codeof(err):
    """The section 12 code of an error, or '' for one this library did not
    raise. The corpus compares by code, so the driver needs one place
    that knows how to read it."""
    return getattr(err, 'code', '')
