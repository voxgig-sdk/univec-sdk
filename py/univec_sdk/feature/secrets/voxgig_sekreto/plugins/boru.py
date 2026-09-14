# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/boru.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The boru plugin: a boru vault through its CLI, or over `boru vault
# serve`. Needs a child process, or HTTPS in wire mode. A port of
# typescript/plugins/boru.ts.
import os
import subprocess

from ..addr import checkaddr
from ..sekreto import SekretoError, checkname
from ..providers import Provider, providerplugin
from .httpjson import fetchjson


class BoruProvider(Provider):
    """A boru vault (https://github.com/boru-lang/boru).

    Two ways in, both boru's own.

    With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
    secret on stdout and nothing else. The passphrase is read by boru
    itself from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as
    config and never puts it on a command line, where it would show up in
    the process table.

    With an `addr`, boru's wire protocol: `boru vault serve` publishes a
    read-only, HashiCorp-shaped provision API (boru's
    design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
    from `boru vault grant`. A sekreto name is already a valid boru
    alias, and boru aliases keep their dots, so `api.token` is the single
    path segment `api.token` - not the `api`/`token` split a HashiCorp KV
    gets. The value is the `value` field. A 404 is a miss; anything else
    the server refuses (a revoked capability, a sealed vault) is an
    error.

    boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
    credential *broker*, built precisely so the caller never receives the
    credential. `vault serve` is the provision endpoint, built to hand
    the value back - that is the one sekreto uses.
    """

    def __init__(self, command=None, namespace=None, home=None,
                 addr=None, token=None, mount=None):
        self.command = command or 'boru'
        self.namespace = namespace
        self.home = home
        self.addr = addr.rstrip('/') if addr else None
        self.token = token
        self.mount = mount or 'secret'

    def lookup(self, name):
        checkname(name)

        if self.addr:
            return self.wirelookup(name)

        alias = self.namespace + ':' + name if self.namespace else name

        env = dict(os.environ)
        if self.home:
            env['BORU_HOME'] = self.home

        try:
            run = subprocess.run(
                [self.command, 'vault', 'get', '--reveal', alias],
                capture_output=True,
                text=True,
                env=env,
                # Not inherited: a CLI that reads stdin - one prompting for a
                # passphrase when its environment variable is absent - would
                # otherwise block on the parent's own stdin forever, and
                # nothing here sets a timeout. `capture_output` covers only
                # the other two streams.
                stdin=subprocess.DEVNULL,
            )
        except OSError as err:
            raise SekretoError('sekreto: cannot run ' + self.command + ': ' + str(err))

        if 0 == run.returncode:
            # boru prints the value and one newline, and nothing else.
            return run.stdout[:-1] if run.stdout.endswith('\n') else run.stdout

        why = (run.stderr or '').strip()

        # "no alias named" is boru saying it does not hold this secret, which
        # is a miss: the chain carries on to the next provider. A locked vault
        # or a wrong passphrase is not a miss - treating it as one would fall
        # through to a weaker store without saying so.
        if borumiss(why):
            return None

        raise SekretoError(
            'sekreto: boru vault error: ' + (why or 'exit ' + str(run.returncode))
        )

    def wirelookup(self, name):
        checkaddr(self.addr)

        alias = self.namespace + '/' + name if self.namespace else name
        url = self.addr + '/v1/' + self.mount + '/data/' + alias

        status, body = fetchjson('GET', url, {'X-Vault-Token': self.token or ''})

        if 404 == status:
            return None

        if 200 != status:
            raise SekretoError('sekreto: boru serve error: ' + str(status) + ': ' + url)

        data = ((body or {}).get('data') or {}).get('data')
        value = data.get('value') if isinstance(data, dict) else None

        return None if value is None else str(value)

    def describe(self):
        if self.addr:
            return 'boru:' + self.addr
        return 'boru' + (':' + self.namespace if self.namespace else '')


def borumiss(why):
    """Does this boru failure mean "no such secret" rather than "I could not
    answer"? Matched on boru's own wording for a missing alias."""
    return 'no alias named' in why


def _make(spec):
    return BoruProvider(
        spec.get('command'),
        spec.get('namespace'),
        spec.get('home'),
        spec.get('addr'),
        spec.get('token'),
        spec.get('mount'),
    )


# The plugin: the `boru` provider kind, as a voxgig/plugin definition.
boru = providerplugin('boru', _make)
