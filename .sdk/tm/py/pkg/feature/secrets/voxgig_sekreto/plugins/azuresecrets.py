# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/azuresecrets.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The azuresecrets plugin: Azure Key Vault. Needs HTTPS. A port of
# typescript/plugins/azuresecrets.ts.
import time

from ..addr import checkaddr
from ..sekreto import SekretoError, flatname
from ..providers import Provider, providerplugin
from .httpjson import fetchjson, tonumber, urlpart


class AzuresecretsProvider(Provider):
    """Azure Key Vault.

    `api.token` reads secret `api-token` (dots flattened to `-`; Key
    Vault names allow nothing else), current version. The token comes
    from config, then a client-credentials login when tenant/clientid/
    clientsecret are given, then the IMDS managed-identity endpoint - so
    on Azure's own platform no credential configuration is needed.

    As with GCP, the IMDS call is plain http to a link-local host by
    platform design and carries no credential; the login and vault
    addresses are `checkaddr`-guarded.
    """

    RESOURCE = 'https://vault.azure.net'

    def __init__(self, options=None):
        self.opts = options or {}

        # A configured token is kept forever; logged-in and IMDS tokens carry
        # expires_in and are renewed shortly before they run out.
        self.livetoken = None
        self.renewat = float('inf')

    def expiry(self, expires):
        seconds = tonumber(expires)
        return time.time() + max(seconds - 60, 1) if 0 < seconds else float('inf')

    def login(self):
        opts = self.opts

        if opts.get('token'):
            return opts['token']

        if opts.get('tenant') and opts.get('clientid') and opts.get('clientsecret'):
            loginaddr = opts.get('loginaddr') or 'https://login.microsoftonline.com'
            checkaddr(loginaddr)

            url = loginaddr.rstrip('/') + '/' + opts['tenant'] + '/oauth2/v2.0/token'
            form = ('grant_type=client_credentials&client_id=' + urlpart(opts['clientid'])
                    + '&client_secret=' + urlpart(opts['clientsecret'])
                    + '&scope=' + urlpart(self.RESOURCE + '/.default'))

            status, body = fetchjson(
                'POST', url, {'content-type': 'application/x-www-form-urlencoded'}, form
            )

            got = (body or {}).get('access_token')
            if 200 != status or not got:
                raise SekretoError('sekreto: azure login failed: ' + str(status))

            self.renewat = self.expiry((body or {}).get('expires_in'))
            return str(got)

        imds = ((opts.get('imdsaddr') or 'http://169.254.169.254').rstrip('/')
                + '/metadata/identity/oauth2/token?api-version=2018-02-01&resource='
                + urlpart(self.RESOURCE))

        status, body = fetchjson('GET', imds, {'Metadata': 'true'})

        got = (body or {}).get('access_token')
        if 200 != status or not got:
            raise SekretoError(
                'sekreto: azure: no token, no client credentials, and IMDS did not answer'
            )

        self.renewat = self.expiry((body or {}).get('expires_in'))
        return str(got)

    def lookup(self, name):
        vault = self.opts.get('vault') or ''
        if '' == vault:
            raise SekretoError('sekreto: azure: no vault')

        # Only an explicit scheme is a URL; a vault NAMED httpvault must
        # still become https://httpvault.vault.azure.net.
        if vault.startswith('http://') or vault.startswith('https://'):
            vaulturl = vault
        else:
            vaulturl = 'https://' + vault + '.vault.azure.net'
        checkaddr(vaulturl)

        if self.livetoken is None or time.time() >= self.renewat:
            self.livetoken = self.login()

        url = (vaulturl.rstrip('/') + '/secrets/' + flatname(name, '-')
               + '?api-version=' + (self.opts.get('apiversion') or '7.4'))

        status, body = fetchjson('GET', url, {'authorization': 'Bearer ' + self.livetoken})

        if 404 == status:
            return None

        if 200 != status:
            raise SekretoError(
                'sekreto: azure error: ' + str(status) + ': ' + url.split('?')[0]
            )

        value = (body or {}).get('value')
        return None if value is None else str(value)

    def describe(self):
        return 'azuresecrets:' + (self.opts.get('vault') or '')


# The plugin: the `azuresecrets` provider kind, as a voxgig/plugin definition.
azuresecrets = providerplugin('azuresecrets', AzuresecretsProvider)
