# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/point.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Extension points (section 6). Three kinds, chosen because they are what
the two existing systems actually needed, and no more.

A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes deactivation
possible: sdkgen's `utility.fetcher = wrapped` is not undoable, but "this
instance holds slot 3 of the request chain" is undoable in O(1). OSGi named
it the whiteboard pattern in 2004, in a paper called *Listeners Considered
Harmful*, and for exactly this reason.
"""

import functools

from .types import fail


# Section 6.1: "fan-out" is not one answer but four. In a language with
# asynchrony, "call every binding" hides a decision - start them all and
# wait, await each in turn, or do not wait - and a design that leaves it
# unsaid gets four different answers from four ports, in the concurrency
# behaviour of production code no corpus entry happens to cover.
MODES = ['emit', 'parallel', 'serial', 'bail']


def emit(bindings, mode, arg):
    """Fan-out. Return values are ignored except in `bail`."""
    if 'bail' == mode:
        # Stops at the first binding that RETURNS A VALUE - the "handled,
        # stop" case. A `None` RETURN DECLINES (section 6.1): python has
        # one way to say nothing, and the model's rule is written to that
        # rather than to JavaScript's null/undefined pair.
        for b in bindings:
            value = b['fn'](arg)
            if None is not value:
                return value
        return None

    errors = []
    for b in bindings:
        try:
            b['fn'](arg)
        except Exception as err:
            # `emit` raises synchronously; the collecting modes gather.
            if 'emit' == mode:
                raise
            errors.append(err)
    return None if 'emit' == mode else errors


def compose(bindings, base):
    """Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section
    6.2).

    Recomputed by the host whenever the live set changes, and cached
    between changes. Plugins receive `next` as an argument; they never see
    or store the previous value of anything. A plugin that stashes `next`
    and calls it after deactivation is a bug the host cannot prevent, and
    this says so rather than pretending otherwise.
    """
    nxt = base
    for i in range(len(bindings) - 1, -1, -1):
        fn = bindings[i]['fn']
        inner = nxt
        # `inner=inner, fn=fn` binds the CURRENT values into the default
        # arguments. Python closures capture the variable, not the value,
        # so a plain closure here would leave every layer calling the last
        # one - the single most common way to get this loop wrong.
        nxt = (lambda *args, fn=fn, inner=inner: fn(inner, *args))
    return nxt


def provider(bindings, spec):
    """At most one live implementation (section 6.3). The winner is the
    highest band, ties broken by ref sort, and THE LOSERS ARE VISIBLE
    rather than silently ignored."""
    if 0 == len(bindings):
        return {'winner': None, 'shadowed': []}

    if spec.get('exclusive') and 1 < len(bindings):
        refs = sorted(b['ref'] for b in bindings)
        fail('plugin_point_exclusive',
             'point is exclusive and has ' + str(len(bindings)) +
             ' bindings: ' + ', '.join(refs),
             {'refs': refs})

    ranked = sorted(bindings, key=functools.cmp_to_key(rank))
    return {'winner': ranked[0], 'shadowed': [b['ref'] for b in ranked[1:]]}


def rank(a, b):
    if a['band'] != b['band']:
        return b['band'] - a['band']       # HIGHEST band wins
    return -1 if a['ref'] < b['ref'] else (1 if a['ref'] > b['ref'] else 0)
