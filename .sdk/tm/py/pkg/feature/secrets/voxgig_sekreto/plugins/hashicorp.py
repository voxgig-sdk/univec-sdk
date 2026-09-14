# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/hashicorp.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The hashicorp plugin: HashiCorp Vault, and OpenBao. Needs HTTPS, and
# the filesystem for a kubernetes service-account JWT. A port of
# typescript/plugins/hashicorp.ts.
import time

from ..addr import checkaddr
from ..sekreto import SekretoError, vaultref, writejson
from ..providers import Provider, providerplugin
from .httpjson import fetchjson, tonumber


class HashicorpProvider(Provider):
    """HashiCorp Vault.

    KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api`
    and takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
    `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means
    "not here" - a miss - so a vault can sit in a chain with fallbacks.

    A Vault Enterprise namespace rides the X-Vault-Namespace header, on
    logins as well as reads.

    Instead of being handed a token, the provider can log in: Kubernetes
    auth (the pod's service-account JWT, from its conventional path) or
    AppRole. A failed login is an error, never a miss - it means this
    store could not answer at all.
    """

    def __init__(self, addr, token, mount=None, kv=None, vaultnamespace=None, auth=None):
        self.addr = addr
        self.mount = mount or 'secret'
        self.kv = kv or 2
        self.vaultnamespace = vaultnamespace
        self.auth = auth

        # A version typo like kv: 3 must not quietly behave as v2 and turn
        # its 404s into misses; there is nothing safe to assume it meant.
        if 1 != self.kv and 2 != self.kv:
            raise SekretoError(
                'sekreto: hashicorp: unsupported kv version: ' + str(self.kv)
            )

        # The working token: a configured token is kept forever, a logged-in
        # token is renewed shortly before its lease runs out - a long-running
        # process must not keep presenting a token the vault already expired.
        self.livetoken = None if '' == token else token
        self.renewat = float('inf')

    def baseheaders(self):
        headers = {}
        if self.vaultnamespace:
            headers['X-Vault-Namespace'] = self.vaultnamespace
        return headers

    def login(self):
        auth = self.auth
        if not auth:
            raise SekretoError('sekreto: hashicorp: no token and no auth method')

        method = auth.get('method')
        mount = auth.get('mount') or method
        url = self.addr.rstrip('/') + '/v1/auth/' + str(mount) + '/login'

        if 'kubernetes' == method:
            jwt = auth.get('jwt')
            if jwt is None:
                file = (
                    auth.get('jwtfile')
                    or '/var/run/secrets/kubernetes.io/serviceaccount/token'
                )
                try:
                    with open(file, 'r', encoding='utf8') as handle:
                        jwt = handle.read().strip()
                except OSError:
                    raise SekretoError('sekreto: hashicorp: cannot read jwt file ' + file)
            body = {'role': auth.get('role') or '', 'jwt': jwt}
        elif 'approle' == method:
            body = {
                'role_id': auth.get('roleid') or '',
                'secret_id': auth.get('secretid') or '',
            }
        else:
            raise SekretoError(
                'sekreto: hashicorp: unknown auth method: ' + str(method)
            )

        status, resbody = fetchjson(
            'POST', url, self.baseheaders(), writejson(body)
        )

        got = ((resbody or {}).get('auth') or {}).get('client_token')
        if 200 != status or not got:
            raise SekretoError(
                'sekreto: hashicorp login failed: ' + str(status) + ': ' + url
            )

        lease = tonumber(((resbody or {}).get('auth') or {}).get('lease_duration'))
        self.renewat = time.time() + max(lease - 60, 1) if 0 < lease else float('inf')

        return str(got)

    def lookup(self, name):
        checkaddr(self.addr)

        if self.livetoken is None or time.time() >= self.renewat:
            self.livetoken = self.login()

        ref = vaultref(name)
        base = self.addr.rstrip('/') + '/v1/' + self.mount
        url = base + '/' + ref['path'] if 1 == self.kv else base + '/data/' + ref['path']

        headers = self.baseheaders()
        headers['X-Vault-Token'] = self.livetoken

        status, body = fetchjson('GET', url, headers)

        if 404 == status:
            return None

        if 200 != status:
            raise SekretoError('sekreto: hashicorp error: ' + str(status) + ': ' + url)

        if 1 == self.kv:
            data = (body or {}).get('data')
        else:
            data = ((body or {}).get('data') or {}).get('data')

        value = data.get(ref['field']) if isinstance(data, dict) else None

        return None if value is None else str(value)

    def describe(self):
        return 'hashicorp:' + self.addr + '/' + self.mount


def _make(spec):
    return HashicorpProvider(
        spec.get('addr') or '',
        spec.get('token') or '',
        spec.get('mount'),
        spec.get('kv'),
        spec.get('vaultnamespace'),
        spec.get('auth'),
    )


# The plugin: the `hashicorp` provider kind, as a voxgig/plugin definition.
hashicorp = providerplugin('hashicorp', _make)
