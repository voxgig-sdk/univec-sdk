# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/capability.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Capabilities (section 11.1).

A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a dependency
on something that can do the job, and which instance is doing it is
exactly the configuration detail a plugin must not care about.

But A BINDING IS TO AN INSTANCE, not to a capability, which is what
decides behaviour when the bound provider leaves while another match
remains.
"""

import functools

from .version import satisfiesq


def resolve_capability(req, candidates):
    """Rank the matching live providers and return them best-first:
    highest `version`, then LOWEST `priority` (default 0), then
    declaration position `pos` ascending.

    `priority` is a field on the capability rather than section 7's
    `order` band, because bands live on POINT BINDINGS: a provider may
    have several bindings with different bands, or none at all, so a rank
    reaching for one would be undefined in the common case.

    Without a total rank, "any provider satisfies" is true of the GRAPH
    and useless to the PLUGIN - two ports could bind different `store`
    instances, both resolve green, and behave differently, which is
    precisely the divergence a shared corpus exists to catch.
    """
    hits = [c for c in candidates if matches(req, c.get('provides') or {})]
    return sorted(hits, key=functools.cmp_to_key(rank))


def rank(a, b):
    ap, bp = a.get('provides') or {}, b.get('provides') or {}
    av, bv = ap.get('version'), bp.get('version')
    if av != bv:
        # An ABSENT version sorts LAST, whatever the other is - "no
        # version" loses to every version rather than being read as
        # 0.0.0.
        if None is av:
            return 1
        if None is bv:
            return -1
        found = compare(bv, av)          # highest version FIRST
        if 0 != found:
            return found
    api = ap.get('priority') or 0
    bpi = bp.get('priority') or 0
    if api != bpi:
        return api - bpi                 # lowest priority first
    return (a.get('pos') or 0) - (b.get('pos') or 0)


def matches(req, prov):
    if req.get('name') != prov.get('name'):
        return False

    if None is not req.get('range'):
        if None is prov.get('version'):
            return False
        if not satisfiesq(prov['version'], req['range']):
            return False

    # `match` is checked against the provider's `attrs`, key by key. A key
    # the provider does not carry is a miss, not a pass: a requirement
    # asking for `transactional: true` must not be satisfied by a provider
    # that never said.
    if None is not req.get('match'):
        attrs = prov.get('attrs') or {}
        for key in req['match']:
            if key not in attrs:
                return False
            if not matchvalue(req['match'][key], attrs[key]):
                return False

    return True


def matchvalue(want, got):
    """PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).

    Section 11.1 defines `match` as "a partial match against `attrs`, with
    exactly the semantics voxgig/struct and the omni corpus already define
    for `match` - every leaf in the requirement must be present and equal
    in the capability, keys not mentioned are not checked."

    A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
    "the first two of your three regions" is not something `match` can
    say, and inventing a spelling for it would be inventing the filter
    language section 11.1 explicitly declines to add.
    """
    if isinstance(want, dict):
        if not isinstance(got, dict):
            return False
        for key in want:
            if key not in got:
                return False
            if not matchvalue(want[key], got[key]):
                return False
        return True

    if isinstance(want, list):
        if not isinstance(got, list) or len(want) != len(got):
            return False
        for i in range(len(want)):
            if not matchvalue(want[i], got[i]):
                return False
        return True

    # PYTHON'S `True == 1` IS THE TRAP THIS LINE EXISTS FOR. The canonical
    # compares with `===`, under which `true` and `1` are different
    # values; Python's `==` says they are equal, so a capability
    # advertising `transactional: 1` would satisfy a requirement for
    # `transactional: true` here and nowhere else.
    if isinstance(want, bool) != isinstance(got, bool):
        return False
    return want == got


def compare(a, b):
    pa = [toint(x) for x in a.split('.')]
    pb = [toint(x) for x in b.split('.')]
    for i in range(3):
        x = pa[i] if i < len(pa) else 0
        y = pb[i] if i < len(pb) else 0
        if x != y:
            return -1 if x < y else 1
    return 0


def toint(text):
    try:
        return int(text)
    except ValueError:
        return 0
