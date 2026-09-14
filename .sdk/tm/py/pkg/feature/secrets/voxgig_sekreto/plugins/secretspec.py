# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/secretspec.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The secretspec plugin: SecretSpec, through its CLI. Needs a child
# process. A port of typescript/plugins/secretspec.ts.
import subprocess

from ..sekreto import SekretoError, envkey
from ..providers import Provider, providerplugin


class SecretspecProvider(Provider):
    """SecretSpec (https://secretspec.dev).

    SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
    project needs - plus a chain of its own backends to satisfy them from.
    That makes it the same shape as sekreto one level down, and the reason
    to support it is the same reason sekreto exists: a project that has
    already declared its secrets there should not have to declare them
    again here.

    Read through its CLI, as boru is, because that is the interface it
    offers a program in another language: `secretspec get API_TOKEN`
    prints the value on stdout and nothing else. A sekreto name maps to a
    SecretSpec key exactly as it maps to an environment variable -
    `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
    examples use.

    `backend` selects one of SecretSpec's backends (`--provider`, e.g.
    `keyring` or `dotenv://.env`) and is called `backend` here only
    because `provider` already means something else in this library.

    A reason is required, not optional: SecretSpec records every read in
    an audit log and refuses to read at all without one. sekreto sends
    `sekreto` unless told otherwise, so the audit trail says which tool
    asked.
    """

    def __init__(self, command=None, file=None, profile=None,
                 backend=None, reason=None, prefix=None):
        self.command = command or 'secretspec'
        self.file = file
        self.profile = profile
        self.backend = backend
        self.reason = reason
        self.prefix = prefix

    def lookup(self, name):
        key = envkey(name, self.prefix)

        args = [self.command]
        if self.file:
            args += ['--file', self.file]
        args += ['get', key]
        if self.backend:
            args += ['--provider', self.backend]
        if self.profile:
            args += ['--profile', self.profile]
        args += ['--reason', self.reason or 'sekreto']

        try:
            run = subprocess.run(
                args,
                capture_output=True,
                text=True,
                # See the boru provider: an inherited stdin lets a CLI that
                # prompts block forever.
                stdin=subprocess.DEVNULL,
            )
        except OSError as err:
            raise SekretoError('sekreto: cannot run ' + self.command + ': ' + str(err))

        if 0 == run.returncode:
            # The value and one newline, and nothing else.
            return run.stdout[:-1] if run.stdout.endswith('\n') else run.stdout

        why = (run.stderr or '').strip()

        if secretspecmiss(why, key):
            return None

        raise SekretoError(
            'sekreto: secretspec error: ' + (why or 'exit ' + str(run.returncode))
        )

    def describe(self):
        return 'secretspec' + (':' + self.backend if self.backend else '')


def secretspecmiss(why, key):
    """Does this SecretSpec failure mean "no such secret" rather than "I
    could not answer"?

    SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
    not declare and one declared with no value, and both are misses: this
    store does not hold it, so the chain carries on.

    MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
    `Provider backend 'keyring' not found`, which is a store that could
    not answer at all - and reading that as a miss is the worst failure
    this library has, because the chain then falls through to a weaker
    store without saying so. The key is required to appear, so the two
    cannot be confused."""
    return ("Secret '" + key + "' not found") in why


def _make(spec):
    return SecretspecProvider(
        spec.get('command'),
        spec.get('file'),
        spec.get('profile'),
        spec.get('backend'),
        spec.get('reason'),
        spec.get('prefix'),
    )


# The plugin: the `secretspec` provider kind, as a voxgig/plugin definition.
secretspec = providerplugin('secretspec', _make)
