# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/providers.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# What a provider is, how a provider kind becomes a voxgig/plugin
# definition - and the four BUILT-IN kinds.
#
# A provider answers one question: "do you have this secret?" It returns
# the value, or None to mean "ask the next one". Nothing else about a
# provider is visible to the caller - which is the point: an app reads
# `api.token` and never learns whether it came from the environment, a
# .env file, HashiCorp Vault or a boru vault.
#
# Two failure shapes, and they are never interchangeable. A store that
# does not hold the secret is a MISS (None) - the chain carries on. A
# store that could not answer - bad credentials, unreachable host,
# missing configuration - is an ERROR: falling through there would
# quietly reach for a weaker store.
#
# THIS MODULE IMPORTS NO urllib, NO hashlib AND NO subprocess. What makes
# a kind built in is that it needs nothing of the platform beyond reading
# a local file; every kind that opens a socket, signs a request or spawns
# a process is a plugin under plugins/, its own module, imported only by
# a program that names it (docs/design/plugin-providers.md).
#
# A port of typescript/src/provider/support.ts and
# typescript/src/provider/builtin.ts, which are canonical.

import os

from ..voxgig_plugin import PluginError

from .sekreto import SekretoError, envkey, parsedotenv


class Provider:
    """A source of secrets. `lookup` returns the value or None."""

    def lookup(self, name):
        raise NotImplementedError

    def describe(self):
        raise NotImplementedError


class EnvProvider(Provider):
    """Environment variables: `api.token` from `API_TOKEN`."""

    def __init__(self, prefix=None, source=None):
        self.prefix = prefix
        self.source = source if source is not None else os.environ

    def lookup(self, name):
        value = self.source.get(envkey(name, self.prefix))
        return None if value is None else str(value)

    def describe(self):
        return 'env' + (':' + self.prefix if self.prefix else '')


class DotenvProvider(Provider):
    """A `.env` file, read once, keyed exactly like the environment."""

    def __init__(self, file, prefix=None):
        self.file = file
        self.prefix = prefix
        self.values = None

    def load(self):
        if self.values is None:
            try:
                with open(self.file, 'r', encoding='utf8') as handle:
                    self.values = parsedotenv(handle.read())
            except (FileNotFoundError, NotADirectoryError):
                # An absent file - or an absent directory - means "no
                # secrets here", exactly like FileProvider. Anything else
                # (permission denied, an unreadable mount) is a store that
                # could not answer, and swallowing it would fall through to
                # a weaker store.
                self.values = {}
            except OSError as err:
                raise SekretoError(
                    'sekreto: dotenv provider cannot read ' + self.file + ': ' + str(err)
                )
        return self.values

    def lookup(self, name):
        return self.load().get(envkey(name, self.prefix))

    def describe(self):
        return 'dotenv:' + self.file


class MemoryProvider(Provider):
    """Literal values, keyed like environment variables. The spec uses this
    to test chain behaviour without touching the outside world."""

    def __init__(self, values, prefix=None):
        self.values = values or {}
        self.prefix = prefix

    def lookup(self, name):
        return self.values.get(envkey(name, self.prefix))

    def describe(self):
        return 'memory' + (':' + self.prefix if self.prefix else '')


class FileProvider(Provider):
    """A directory of one-secret-per-file entries, keyed like the
    environment: `api.token` reads `<dir>/API_TOKEN`.

    This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
    secret, and a systemd credentials directory, so those all work with no
    further configuration. One trailing newline is stripped - tools that
    write these files disagree about it, and a newline is never part of a
    secret on purpose.
    """

    def __init__(self, dir, prefix=None):
        self.dir = dir
        self.prefix = prefix

    def lookup(self, name):
        file = os.path.join(self.dir, envkey(name, self.prefix))

        try:
            with open(file, 'r', encoding='utf8') as handle:
                text = handle.read()
        except (FileNotFoundError, NotADirectoryError):
            # An absent file - or an absent directory - means "no secrets
            # here", exactly like a missing .env. Anything else (permission
            # denied, an unreadable mount) is a store that could not answer.
            return None
        except OSError as err:
            raise SekretoError(
                'sekreto: file provider cannot read ' + file + ': ' + str(err)
            )

        if text.endswith('\r\n'):
            return text[:-2]
        if text.endswith('\n'):
            return text[:-1]
        return text

    def describe(self):
        return 'file:' + self.dir


# --- providers as voxgig/plugin definitions -------------------------------

# The export key under which a provider definition publishes the provider
# it built. `Sekreto` reads `<ref>/provider` off the host.
PROVIDER_EXPORT = 'provider'

# The voxgig/plugin error code a SekretoError travels under when it is
# raised inside a definition's `define`.
#
# plugin wraps a code-less error raised by a callback as
# `plugin_define_failed`, and keeps an error that already carries a code.
# A provider that refuses its own configuration - `kv: 3`, a missing
# project - raises a SekretoError, and that message is pinned by the spec
# byte for byte, so it must come back out of the host exactly as it went
# in. `providerplugin` gives it this code on the way in; `Sekreto` turns
# it back into a SekretoError on the way out.
ERROR_CODE = 'sekreto_error'


def providerplugin(kind, make):
    """A provider kind, as a voxgig/plugin definition.

    This is the whole bridge between the two libraries. The definition's
    `name` is the `kind` a spec names; its `define` reads the spec as
    `inst.options`, builds the provider with `make`, and exports it.
    Nothing runs at `activate`: a provider opens nothing until its first
    lookup, so there is nothing to capture - a provider that does hold a
    resource acquires it there and lets the instance scope unwind it.

    Every built-in and every plugin is made this way, so a custom
    provider kind is one call:

        providerplugin('mystore', lambda spec: MyStore(spec.get('addr')))
    """
    def define(inst):
        try:
            provider = make(inst.options)
        except SekretoError as err:
            raise PluginError(ERROR_CODE, str(err), {'ref': inst.ref, 'cause': str(err)})
        inst.export(PROVIDER_EXPORT, provider)

    return {'name': kind, 'define': define}


# The four built-in provider kinds - the same four in every port. What
# makes a kind built in is that it needs nothing of the platform beyond
# reading a local file: no socket, no TLS, no crypto, no child process.
BUILTINS = [
    providerplugin('env', lambda spec: EnvProvider(spec.get('prefix'))),
    providerplugin('memory', lambda spec: MemoryProvider(spec.get('values') or {}, spec.get('prefix'))),
    providerplugin('dotenv', lambda spec: DotenvProvider(spec.get('file') or '.env', spec.get('prefix'))),
    providerplugin('file', lambda spec: FileProvider(spec.get('dir') or '', spec.get('prefix'))),
]

# Every kind this library ships, built in or as a plugin, so that an
# unknown kind can be told from a plugin that was not loaded.
KINDS = {
    'builtin': ['env', 'memory', 'dotenv', 'file'],
    'plugin': [
        'hashicorp', 'boru', 'awssecrets', 'awsparams', 'gcpsecrets',
        'azuresecrets', 'onepassword', 'doppler', 'infisical', 'secretspec',
    ],
}
