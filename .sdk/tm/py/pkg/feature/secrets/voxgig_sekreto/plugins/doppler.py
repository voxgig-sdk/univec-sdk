# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/doppler.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The doppler plugin: Doppler, one bulk download per config. Needs
# HTTPS. A port of typescript/plugins/doppler.ts.
from ..addr import checkaddr
from ..sekreto import SekretoError, envkey
from ..providers import Provider, providerplugin
from .httpjson import fetchjson, urlpart


class DopplerProvider(Provider):
    """Doppler.

    The whole config is downloaded once - Doppler's own bulk endpoint -
    and answered from memory, like a remote .env: `api.token` is the
    `API_TOKEN` entry. A service token is config-scoped, so project and
    config are only needed with broader tokens.
    """

    def __init__(self, options=None):
        self.opts = options or {}
        self.values = None

    def load(self):
        if self.values is not None:
            return self.values

        addr = (self.opts.get('addr') or 'https://api.doppler.com').rstrip('/')
        checkaddr(addr)

        url = addr + '/v3/configs/config/secrets/download?format=json'
        if self.opts.get('project'):
            url += '&project=' + urlpart(self.opts['project'])
        if self.opts.get('config'):
            url += '&config=' + urlpart(self.opts['config'])

        status, body = fetchjson(
            'GET', url, {'authorization': 'Bearer ' + (self.opts.get('token') or '')}
        )

        if 200 != status or not isinstance(body, dict):
            raise SekretoError('sekreto: doppler error: ' + str(status))

        self.values = {}
        for key, value in body.items():
            if value is not None:
                self.values[key] = str(value)

        return self.values

    def lookup(self, name):
        return self.load().get(envkey(name))

    def describe(self):
        if self.opts.get('project'):
            return 'doppler:' + self.opts['project'] + '/' + (self.opts.get('config') or '')
        return 'doppler'


# The plugin: the `doppler` provider kind, as a voxgig/plugin definition.
doppler = providerplugin('doppler', DopplerProvider)
