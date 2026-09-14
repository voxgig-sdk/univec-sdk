# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/order.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Ordering (section 7) - one rule, one place.

sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
and the third was not far off. This sort is the whole replacement, and the
tiers are in this order for a reason:

  1 constraints   before/after edges, by ref or by name
  2 bands         integer, lower first, default 0
  3 declaration   ties break by `pos`

CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
present. A band expresses a genuine cross-cutting layer; a constraint
expresses a relationship between two specific things; and a band chosen by
trial and error to fix an ordering bug is a bug wearing a number.
"""

from .types import fail
from .ref import parse_ref


def resolve_order(bindings, pin=None):
    nodes = list(bindings)
    byref = {b['ref']: b for b in nodes}

    # Constraints are edges. A constraint naming an ABSENT binding is
    # satisfied VACUOUSLY (section 7) - a plugin ordered `after: 'test'`
    # must load in a host with no test plugin. That is sdkgen's __after__
    # behaviour, kept.
    edges = {b['ref']: [] for b in nodes}

    for b in nodes:
        block = b.get('order') or {}
        # An ABSENT constraint and an EMPTY LIST are both "no constraint".
        if declared(block.get('after')):
            for target in targets(block['after'], nodes):
                edges[target].append(b['ref'])
        if declared(block.get('before')):
            for target in targets(block['before'], nodes):
                edges[b['ref']].append(target)

    # Stable topological sort. Among ready nodes, band first (lower runs
    # first), then `pos` - the position the DOCUMENT visibly states, not
    # the order instances happened to load and not the incarnation `seq`.
    indeg = {b['ref']: 0 for b in nodes}
    for source in edges:
        for target in edges[source]:
            indeg[target] = indeg.get(target, 0) + 1

    out = []
    ready = [b for b in nodes if 0 == indeg[b['ref']]]

    while 0 < len(ready):
        ready.sort(key=lambda b: (band(b), b.get('pos') or 0))
        nxt = ready.pop(0)
        out.append(nxt['ref'])
        for target in edges[nxt['ref']]:
            indeg[target] -= 1
            if 0 == indeg[target]:
                ready.append(byref[target])

    if len(out) != len(nodes):
        stuck = [b['ref'] for b in nodes if b['ref'] not in out]
        fail('plugin_order_cycle',
             'before/after constraints cycle: ' + ' -> '.join(stuck),
             {'cycle': stuck})

    return applypin(out, edges, pin)


def band(b):
    block = b.get('order') or {}
    value = block.get('band')
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def declared(spec):
    """Was a constraint stated? An absent value and an EMPTY LIST are
    both no-constraint - and an empty list is truthy in most languages,
    which is exactly how this class of bug survives."""
    if spec is None:
        return False
    if isinstance(spec, list):
        return any('' != one for one in spec)
    return '' != spec


def targets(spec, nodes):
    """Matching is by REF, or by NAME across all of that definition's
    instances (section 7) - which is the whole reason the two spellings
    exist."""
    hit = []
    # One spelling or a LIST of them. A list fans out to the union of what
    # each names, so after: ['a','b'] means after BOTH, and the same
    # instance named twice - once by name, once by ref - is one edge.
    specs = spec if isinstance(spec, list) else [spec]
    for one in specs:
        for b in nodes:
            if b['ref'] in hit:
                continue
            if b['ref'] == one:
                hit.append(b['ref'])
                continue
            if parse_ref(b['ref'])['name'] == one:
                hit.append(b['ref'])
    return hit


def applypin(order, edges, pin=None):
    """A PIN IS NOT A CONSTRAINT (section 7).

    Constraints and bands are negotiable by definition - they are what
    plugins and documents say they want, and the sort's job is to satisfy
    them all. A pin is the host stating a structural invariant of its own
    architecture, which is a different kind of claim and must not lose a
    tie to a document.

    So a pin PLACES the binding at the named end, and an ordering that
    would move it away is `plugin_order_pinned` - rejected, not honoured
    into a broken wrap. Station's transport adapter must sit immediately
    outside the base transport; an `order` list that moves it has to be an
    error rather than a preference.
    """
    if None is pin:
        return order
    out = list(order)

    # SORTED, not insertion order. A pin map is data - it can arrive from
    # a host's own construction options in any order, and two names
    # pinned to the same end are order-sensitive (`{b:'first',
    # a:'first'}` and `{a:'first', b:'first'}` give different results).
    # Python dicts are insertion-ordered and a Go map has no order at
    # all, so leaving it unstated made the same declaration mean
    # different things in different ports.
    for name in sorted(pin):
        want = pin[name]
        idx = -1
        for i, ref in enumerate(out):
            if parse_ref(ref)['name'] == name:
                idx = i
                break
        if -1 == idx:
            continue

        # `first`/`outermost` is index 0; `last`/`innermost` is the end.
        # Section 6.2 makes the first chain binding outermost, which is
        # why the vocabulary is positional and why the two spellings pair
        # this way.
        wantfirst = 'first' == want or 'outermost' == want
        ref = out.pop(idx)
        if wantfirst:
            out.insert(0, ref)
        else:
            out.append(ref)

    # Now check that the placement did not break a constraint. This is the
    # half that makes a pin a rejection rather than an override: the host
    # wins on position, but it does not get to silently discard a
    # relationship a plugin declared.
    at = {ref: i for i, ref in enumerate(out)}
    for source in edges:
        for target in edges[source]:
            if at[source] > at[target]:
                fail('plugin_order_pinned',
                     'a pin would move a binding an ordering constrains: ' +
                     source + ' must precede ' + target,
                     {'before': source, 'after': target})

    return out
