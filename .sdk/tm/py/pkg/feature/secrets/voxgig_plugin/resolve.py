# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/resolve.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Dynamic resolution (section 10.2) - name to candidate module ids.

PURE. It returns the ids a host WOULD try, in order; it does not load
anything. That separation is what lets the corpus pin resolution in every
language including those with no dynamic loading at all, and it is why
section 15.4 puts real module loading in per-port integration tests rather
than here.
"""

DEFAULT_SOURCES = [
    {'kind': 'module',
     'prefix': ['@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', '']},
]


def resolve_candidates(name, sources=None):
    out = []

    # A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing`
    # is already a package id; prefixing it produces
    # `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    if name.startswith('@'):
        return [name]

    entries = sources if sources else DEFAULT_SOURCES

    for src in entries:
        if 'module' == src.get('kind'):
            prefixes = src.get('prefix') or ['']
            if 0 == len(prefixes):
                prefixes = ['']
            for prefix in prefixes:
                found = prefix + name
                if found not in out:
                    out.append(found)
        elif 'path' == src.get('kind'):
            found = src['dir'].rstrip('/') + '/' + name
            if found not in out:
                out.append(found)

    return out


def resolve_from(location):
    """A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts
    a name with a letter or `@`, so `./local/thing` is not a ref and never
    reaches candidate generation - seneca allows a path where a plugin
    name goes, and this design deliberately does not, because a ref is an
    ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.

    Loading from an explicit location is a separate field that bypasses
    candidate generation entirely: `from` is passed to the resolver
    verbatim, and a resolver that cannot honour a location raises
    plugin_resolve_failed.
    """
    return [location]
