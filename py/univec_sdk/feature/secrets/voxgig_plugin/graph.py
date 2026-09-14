# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/graph.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Whole-graph resolution (section 11.4) - a phase, not a discovery.

"Activate, and wait in `pending` if you must" is correct and, on its own,
produces a terrible experience: apply twenty instances against a registry
missing one thing and you get NINETEEN pending rows and no statement of
what is actually wrong.

`resolve_graph` is a PURE FUNCTION of the registry and the intended
activation set. No callbacks run, no state changes, nothing is touched. It
answers for the whole graph at once which instances can be live, and for
each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.

The failure mode being designed against is a famous one: OSGi's resolver
is correct and its diagnostics are legendarily unusable. A resolver that
says "blocked" without saying WHY has moved the problem rather than solved
it, so `why` is part of the contract and the corpus pins its shape.
"""

from .capability import resolve_capability, matchvalue
from .version import satisfiesq
from .ref import try_ref


def resolve_graph(nodes):
    byref = {}
    for node in nodes:
        byref[node['ref']] = node

    resolved = set()
    blocked = {}

    # Fixed point: a node resolves when every mandatory requirement is met
    # by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
    # makes a provider that is itself blocked propagate, rather than each
    # node being judged against the raw registry.
    moved = True
    while moved:
        moved = False
        for node in nodes:
            if node['ref'] in resolved:
                continue
            if None is firstunmet(node, byref, resolved):
                resolved.add(node['ref'])
                moved = True

    for node in nodes:
        if node['ref'] in resolved:
            continue
        why = firstunmet(node, byref, resolved)
        if None is not why:
            blocked[node['ref']] = why

    return {
        'resolved': sorted(resolved),
        'blocked': [blocked[r] for r in sorted(blocked)],
    }


def firstunmet(node, byref, resolved):
    """The FIRST unmet requirement, with the most specific explanation
    available. Order matters: "no provider at all" and "a provider at the
    wrong version" are different problems and a reader must not have to
    guess which they have."""
    for req in node.get('requires') or []:
        if req.get('optional'):
            continue

        allof = candidates(byref, req['name'])
        if 0 == len(allof):
            return {'ref': node['ref'], 'unmet': req['name'],
                    'why': {'kind': 'absent'}}

        ok = resolve_capability(req, allof)
        if 0 < len(ok):
            # A provider exists and matches - but if none of them is
            # itself resolved, this node is blocked BEHIND it, and the
            # chain is the useful answer rather than "unmet".
            live = [c for c in ok if c['ref'] in resolved]
            if 0 < len(live):
                continue
            return {'ref': node['ref'], 'unmet': req['name'],
                    'why': {'kind': 'blocked',
                            'chain': sorted(c['ref'] for c in ok)}}

        # Providers exist and none matched. Say which test failed.
        if None is not req.get('range'):
            versions = [
                (c['provides'].get('version') or '(none)')
                for c in allof
                if None is c['provides'].get('version')
                or not satisfiesq(c['provides']['version'], req['range'])
            ]
            if 0 < len(versions):
                return {'ref': node['ref'], 'unmet': req['name'],
                        'why': {'kind': 'version', 'range': req['range'],
                                'found': sorted(versions)}}

        if None is not req.get('match'):
            for c in allof:
                attrs = c['provides'].get('attrs') or {}
                for key in sorted(req['match']):
                    if key not in attrs or not matchvalue(req['match'][key],
                                                          attrs[key]):
                        return {
                            'ref': node['ref'], 'unmet': req['name'],
                            'why': {
                                'kind': 'match', 'failing': key,
                                'want': req['match'][key],
                                'found': attrs.get(key),
                            },
                        }

        return {'ref': node['ref'], 'unmet': req['name'],
                'why': {'kind': 'absent'}}
    return None


def candidates(byref, name):
    out = []
    # A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned
    # it here. Considering only declared capabilities made `resolve()`
    # answer `absent` about a provider sitting right there and live.
    asref = try_ref(name)
    for ref in sorted(byref):
        node = byref[ref]
        # The ref match WINS OUTRIGHT for that node, as at runtime: one
        # candidate, not two, for a node both named `b` and providing `b`.
        if ref == asref:
            out.append({'ref': node['ref'], 'pos': node.get('pos') or 0,
                        'provides': {'name': name}})
            continue
        for prov in node.get('provides') or []:
            if prov.get('name') == name:
                out.append({'ref': node['ref'], 'pos': node.get('pos') or 0,
                            'provides': prov})
    return out
