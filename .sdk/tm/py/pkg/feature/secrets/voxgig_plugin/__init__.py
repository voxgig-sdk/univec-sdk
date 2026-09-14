# VENDORED: @voxgig/plugin 0.1.6 (python/voxgig_plugin/__init__.py)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
"""The canonical surface `make parity` checks (AGENTS.md section 4).

Small on purpose (section 19): everything else is methods on the host and
instance types, because a library that grows a second public entry point
per feature is a library twenty ports pay for twice.
"""

from .types import PluginError, formaterror, codeof, DETAIL_ORDER, STATUSES
from .ref import parse_ref, format_ref, check_name, check_tag, canon_ref
from .config import normalize_config, resolve_options, check_shape
from .order import resolve_order
from .resolve import resolve_candidates, resolve_from
from .env import apply_env, encode_ref
from .version import parse_range, parse_version, satisfies
from .capability import resolve_capability, matches
from .graph import resolve_graph
from .point import emit, compose, provider
from .export import resolve_export
from .catalog import make_catalog, Catalog
from .host import make_host, Host, Inst

__all__ = [
    'make_host', 'make_catalog',
    'parse_ref', 'format_ref', 'check_name', 'check_tag', 'canon_ref',
    'normalize_config', 'resolve_options', 'check_shape',
    'resolve_order', 'resolve_candidates', 'resolve_from',
    'apply_env', 'encode_ref',
    'parse_range', 'parse_version', 'satisfies',
    'resolve_capability', 'matches', 'resolve_graph',
    'emit', 'compose', 'provider', 'resolve_export',
    'PluginError', 'formaterror', 'codeof', 'DETAIL_ORDER', 'STATUSES',
    'Catalog', 'Host', 'Inst',
]
