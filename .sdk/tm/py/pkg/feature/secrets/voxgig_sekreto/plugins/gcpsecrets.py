# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/gcpsecrets.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The gcpsecrets plugin: GCP Secret Manager. Needs HTTPS. A port of
# typescript/plugins/gcpsecrets.ts.
import base64
import os
import time

from ..addr import checkaddr
from ..sekreto import SekretoError, flatname
from ..providers import Provider, providerplugin
from .httpjson import fetchjson, tonumber


class GcpsecretsProvider(Provider):
    """GCP Secret Manager.

    `api.token` reads secret `api_token` (dots flattened to `_`; Secret
    Manager ids have no hierarchy and reject dots), latest version. The
    token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
    GCE/GKE metadata server - so on Google's own platform no credential
    configuration is needed at all.

    The metadata call itself is plain http to a link-local host by
    platform design; no credential rides on it, so `checkaddr` guards the
    Secret Manager address instead.
    """

    def __init__(self, options=None):
        self.opts = options or {}

        # A configured token is kept forever; a metadata-server token carries
        # expires_in and is renewed shortly before it runs out.
        self.livetoken = None
        self.renewat = float('inf')

    def metadataaddr(self):
        if self.opts.get('metadataaddr'):
            return self.opts['metadataaddr']
        host = os.environ.get('GCE_METADATA_HOST')
        return 'http://' + host if host else 'http://metadata.google.internal'

    def login(self):
        configured = self.opts.get('token') or os.environ.get('GOOGLE_OAUTH_ACCESS_TOKEN')
        if configured:
            return configured

        url = (self.metadataaddr().rstrip('/')
               + '/computeMetadata/v1/instance/service-accounts/default/token')

        status, body = fetchjson('GET', url, {'Metadata-Flavor': 'Google'})

        got = (body or {}).get('access_token')
        if 200 != status or not got:
            raise SekretoError('sekreto: gcp: no token and metadata server did not answer')

        expires = tonumber((body or {}).get('expires_in'))
        self.renewat = time.time() + max(expires - 60, 1) if 0 < expires else float('inf')

        return str(got)

    def lookup(self, name):
        project = self.opts.get('project') or ''
        if '' == project:
            raise SekretoError('sekreto: gcp: no project')

        addr = self.opts.get('addr') or 'https://secretmanager.googleapis.com'
        checkaddr(addr)

        if self.livetoken is None or time.time() >= self.renewat:
            self.livetoken = self.login()

        url = (addr.rstrip('/') + '/v1/projects/' + project + '/secrets/'
               + flatname(name, '_') + '/versions/latest:access')

        status, body = fetchjson('GET', url, {'authorization': 'Bearer ' + self.livetoken})

        if 404 == status:
            return None

        if 200 != status:
            raise SekretoError('sekreto: gcp error: ' + str(status) + ': ' + url)

        data = ((body or {}).get('payload') or {}).get('data')
        if not isinstance(data, str):
            return None

        # See the aws provider: validate=True, and an undecodable payload
        # is an error rather than a miss.
        try:
            return base64.b64decode(data, validate=True).decode('utf8')
        except Exception:
            raise SekretoError('sekreto: gcp: undecodable secret')

    def describe(self):
        return 'gcpsecrets:' + (self.opts.get('project') or '')


# The plugin: the `gcpsecrets` provider kind, as a voxgig/plugin definition.
gcpsecrets = providerplugin('gcpsecrets', GcpsecretsProvider)
