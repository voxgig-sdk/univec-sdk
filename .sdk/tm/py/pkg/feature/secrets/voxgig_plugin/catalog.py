# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/catalog.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""The definition catalog (section 10.1).

A definition is registered once and may back many instances. Option shapes
are validated AT REGISTRATION, not when a document happens to exercise a
key - so a malformed shape fails once, and in the same place everywhere
(section 9.4).
"""

from .types import fail
from .ref import check_name
from .config import check_shape


class Catalog:
    def __init__(self):
        self._defs = {}

    def add(self, definition):
        if not isinstance(definition, dict) or \
                not check_name(definition.get('name')):
            name = definition.get('name') if isinstance(definition, dict) \
                else definition
            fail('plugin_definition_name',
                 'invalid definition name: ' + str(name))
        # Validate the shape HERE. Deferring it to resolution time means a
        # malformed shape surfaces at a different moment in every host
        # that loads it, which is the divergence the stated domain exists
        # to prevent.
        if definition.get('shape'):
            check_shape(definition['shape'])
        self._defs[definition['name']] = definition

    def get(self, name):
        return self._defs.get(name)

    def has(self, name):
        return name in self._defs

    def names(self):
        return sorted(self._defs)


def make_catalog(definitions=None):
    catalog = Catalog()
    for definition in definitions or []:
        catalog.add(definition)
    return catalog
