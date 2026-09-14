# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/export.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""Exports (section 11).

An instance publishes values for other plugins and for the application.
Read with `host.exports('retry$fast/client')`.

THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves to
the UNTAGGED instance if one exists; if not, and exactly one tagged
instance exports that key, it resolves to that one; if two do, it is
`plugin_export_ambiguous` - deliberately diverging from seneca's silent
last-wins, because with multi-instance as a headline feature an ambiguous
alias is a defect waiting for production.
"""

from .types import fail
from .ref import canon_ref, parse_ref


def resolve_export(spec, exported):
    cut = spec.find('/')
    if -1 == cut:
        fail('plugin_export_ambiguous', 'export spec needs a key: ' + spec,
             {'spec': spec})
    head = spec[:cut]
    key = spec[cut + 1:]

    # A fully qualified ref: exactly one answer or none.
    want = canon_ref(head)
    for entry in exported:
        if entry['ref'] == want and entry['key'] == key:
            return entry['value']

    # An alias: the name, not a ref. Look at every instance of it.
    byname = [e for e in exported
              if parse_ref(e['ref'])['name'] == head and e['key'] == key]
    if 0 == len(byname):
        return None

    for entry in byname:
        if '' == parse_ref(entry['ref'])['tag']:
            return entry['value']

    if 1 == len(byname):
        return byname[0]['value']

    refs = sorted(e['ref'] for e in byname)
    fail('plugin_export_ambiguous',
         'alias ' + spec + ' matches ' + str(len(refs)) + ' instances: ' +
         ', '.join(refs),
         {'spec': spec, 'refs': refs})
