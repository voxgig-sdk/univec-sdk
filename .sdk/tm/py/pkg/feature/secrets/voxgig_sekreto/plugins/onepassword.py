# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/onepassword.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The onepassword plugin: 1Password, through a Connect server. Needs
# HTTPS. A port of typescript/plugins/onepassword.ts.
from ..addr import checkaddr
from ..sekreto import SekretoError, checkname
from ..providers import Provider, providerplugin
from .httpjson import fetchjson, urlpart


class OnepasswordProvider(Provider):
    """1Password, through a Connect server.

    The item titled `api.token` (titles keep their dots), in the named
    vault. The value is the field with purpose PASSWORD, or the field
    labelled `value`. A vault that cannot be found is an error - config
    names it, so its absence is a broken store, not a missing secret.
    """

    def __init__(self, options=None):
        self.opts = options or {}
        self.vaultid = None

    def authheaders(self):
        return {'authorization': 'Bearer ' + (self.opts.get('token') or '')}

    def resolvevault(self, addr):
        want = self.opts.get('vault') or ''
        if '' == want:
            raise SekretoError('sekreto: onepassword: no vault')

        status, body = fetchjson('GET', addr + '/v1/vaults', self.authheaders())

        if 200 != status or not isinstance(body, list):
            raise SekretoError(
                'sekreto: onepassword error: ' + str(status) + ': listing vaults'
            )

        for entry in body:
            if isinstance(entry, dict) and (want == entry.get('id') or want == entry.get('name')):
                return str(entry.get('id'))

        raise SekretoError('sekreto: onepassword: no vault named ' + want)

    def lookup(self, name):
        checkname(name)

        addr = (self.opts.get('addr') or '').rstrip('/')
        if '' == addr:
            raise SekretoError('sekreto: onepassword: no addr')
        checkaddr(addr)

        if self.vaultid is None:
            self.vaultid = self.resolvevault(addr)

        filterpart = urlpart('title eq "' + name + '"')
        status, found = fetchjson(
            'GET',
            addr + '/v1/vaults/' + self.vaultid + '/items?filter=' + filterpart,
            self.authheaders(),
        )

        if 200 != status or not isinstance(found, list):
            raise SekretoError(
                'sekreto: onepassword error: ' + str(status) + ': finding ' + name
            )

        if 0 == len(found):
            return None

        status, item = fetchjson(
            'GET',
            addr + '/v1/vaults/' + self.vaultid + '/items/' + str(found[0].get('id')),
            self.authheaders(),
        )

        if 200 != status:
            raise SekretoError(
                'sekreto: onepassword error: ' + str(status) + ': reading ' + name
            )

        fields = (item or {}).get('fields') or []

        for field in fields:
            if isinstance(field, dict) and 'PASSWORD' == field.get('purpose'):
                value = field.get('value')
                return None if value is None else str(value)
        for field in fields:
            if isinstance(field, dict) and 'value' == field.get('label'):
                value = field.get('value')
                return None if value is None else str(value)

        return None

    def describe(self):
        return 'onepassword:' + (self.opts.get('vault') or '')


# The plugin: the `onepassword` provider kind, as a voxgig/plugin definition.
onepassword = providerplugin('onepassword', OnepasswordProvider)
