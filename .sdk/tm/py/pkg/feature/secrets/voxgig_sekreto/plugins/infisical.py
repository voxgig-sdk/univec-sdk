# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/infisical.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The infisical plugin: Infisical. Needs HTTPS. A port of
# typescript/plugins/infisical.ts.
import time

from ..addr import checkaddr
from ..sekreto import SekretoError, envkey, writejson
from ..providers import Provider, providerplugin
from .httpjson import fetchjson, tonumber, urlpart


class InfisicalProvider(Provider):
    """Infisical.

    `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
    convention is environment-style keys) at a secret path in one
    environment of a project. Auth is a token, or a universal-auth
    (machine identity) login with clientid/clientsecret.
    """

    def __init__(self, options=None):
        self.opts = options or {}

        # A configured token is kept forever; a universal-auth token carries
        # expiresIn and is renewed shortly before it runs out.
        self.livetoken = None
        self.renewat = float('inf')

    def login(self, addr):
        if self.opts.get('token'):
            return self.opts['token']

        if not self.opts.get('clientid') or not self.opts.get('clientsecret'):
            raise SekretoError('sekreto: infisical: no token and no client credentials')

        status, body = fetchjson(
            'POST',
            addr + '/api/v1/auth/universal-auth/login',
            {'content-type': 'application/json'},
            writejson(
                {'clientId': self.opts['clientid'], 'clientSecret': self.opts['clientsecret']}
            ),
        )

        got = (body or {}).get('accessToken')
        if 200 != status or not got:
            raise SekretoError('sekreto: infisical login failed: ' + str(status))

        expires = tonumber((body or {}).get('expiresIn'))
        self.renewat = time.time() + max(expires - 60, 1) if 0 < expires else float('inf')

        return str(got)

    def lookup(self, name):
        addr = (self.opts.get('addr') or 'https://app.infisical.com').rstrip('/')
        checkaddr(addr)

        project = self.opts.get('project') or ''
        environment = self.opts.get('environment') or ''
        if '' == project or '' == environment:
            raise SekretoError('sekreto: infisical: no project/environment')

        if self.livetoken is None or time.time() >= self.renewat:
            self.livetoken = self.login(addr)

        url = (addr + '/api/v3/secrets/raw/' + envkey(name)
               + '?workspaceId=' + urlpart(project)
               + '&environment=' + urlpart(environment)
               + '&secretPath=' + urlpart(self.opts.get('path') or '/'))

        status, body = fetchjson('GET', url, {'authorization': 'Bearer ' + self.livetoken})

        if 404 == status:
            return None

        if 200 != status:
            raise SekretoError('sekreto: infisical error: ' + str(status))

        value = ((body or {}).get('secret') or {}).get('secretValue')
        return None if value is None else str(value)

    def describe(self):
        return ('infisical:' + (self.opts.get('project') or '')
                + '/' + (self.opts.get('environment') or ''))


# The plugin: the `infisical` provider kind, as a voxgig/plugin definition.
infisical = providerplugin('infisical', InfisicalProvider)
