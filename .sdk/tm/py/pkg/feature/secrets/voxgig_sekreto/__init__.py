# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/__init__.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# voxgig_sekreto - one interface for secrets, wherever they live.
#
# THE CORE SURFACE: the chain, the four built-in provider kinds, and the
# means of adding a fifth.
#
# The built-ins are the kinds that read at most a local file - env,
# memory, dotenv, file. Everything that opens a socket, spawns a process
# or signs a request is a PLUGIN, is not imported by this package, and is
# handed to `Sekreto` by the calling project:
#
#     from .. import Sekreto
#     from voxgig_sekreto.plugins.hashicorp import hashicorp
#
#     secrets = Sekreto({
#         'plugins': [hashicorp],
#         'providers': [{'kind': 'env'}, {'kind': 'hashicorp', 'addr': addr, 'token': token}],
#     })
#
# or, for every kind at once, `ALL` from `voxgig_sekreto.plugins`. See
# docs/design/plugin-providers.md.

from .addr import checkaddr, safeaddr
from .providers import (
    BUILTINS,
    ERROR_CODE,
    KINDS,
    PROVIDER_EXPORT,
    DotenvProvider,
    EnvProvider,
    FileProvider,
    MemoryProvider,
    Provider,
    providerplugin,
)
from .sekreto import (
    Sekreto,
    SekretoError,
    awsparam,
    envkey,
    flatname,
    parsedotenv,
    redact,
    sekreto,
    validname,
    vaultref,
    writejson,
)

__all__ = [
    'BUILTINS',
    'ERROR_CODE',
    'KINDS',
    'PROVIDER_EXPORT',
    'DotenvProvider',
    'EnvProvider',
    'FileProvider',
    'MemoryProvider',
    'Provider',
    'Sekreto',
    'SekretoError',
    'awsparam',
    'checkaddr',
    'envkey',
    'flatname',
    'parsedotenv',
    'providerplugin',
    'redact',
    'safeaddr',
    'sekreto',
    'validname',
    'vaultref',
    'writejson',
]
