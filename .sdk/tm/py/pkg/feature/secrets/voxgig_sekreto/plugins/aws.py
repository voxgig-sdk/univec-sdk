# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/aws.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The aws plugin: Secrets Manager and SSM Parameter Store, with requests
# SigV4-signed in-tree (sigv4.py, beside this file). Needs HTTPS and
# HMAC-SHA256 - the one cryptographic dependency in the library, which is
# why this is a plugin and why the core never imports hashlib or hmac. A
# port of typescript/plugins/aws.ts.
import base64
import json
import os
import time

from ..addr import checkaddr
from ..sekreto import SekretoError, awsparam, vaultref, writejson
from ..providers import Provider, providerplugin
from .httpjson import fetchjson
from .sigv4 import sigv4


def awsnow():
    """The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now."""
    return time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())


def awsauth(opts):
    """Region and credentials, from config first and the standard AWS_*
    environment variables second - those are AWS's own convention, and a
    pod or CI job that has them set should just work. Missing either is
    an error: an AWS store with no credentials could not answer."""
    env = os.environ

    region = opts.get('region') or env.get('AWS_REGION') or env.get('AWS_DEFAULT_REGION') or ''
    keyid = opts.get('keyid') or env.get('AWS_ACCESS_KEY_ID') or ''
    secret = opts.get('secret') or env.get('AWS_SECRET_ACCESS_KEY') or ''
    session = opts.get('session') or env.get('AWS_SESSION_TOKEN') or None

    if '' == region:
        raise SekretoError('sekreto: aws: no region (set region or AWS_REGION)')
    if '' == keyid or '' == secret:
        raise SekretoError(
            'sekreto: aws: no credentials (set keyid/secret or'
            + ' AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)'
        )

    return {'region': region, 'keyid': keyid, 'secret': secret, 'session': session}


def awscall(opts, service, target, payload):
    """One signed call to an AWS JSON-1.1 API."""
    auth = awsauth(opts)
    # The China partition lives under its own suffix; every other
    # commercial region is plain amazonaws.com.
    suffix = '.amazonaws.com.cn' if auth['region'].startswith('cn-') else '.amazonaws.com'
    addr = opts.get('addr') or 'https://' + service + '.' + auth['region'] + suffix
    checkaddr(addr)

    url = addr.rstrip('/') + '/'
    body = writejson(payload)
    headers = {
        'content-type': 'application/x-amz-json-1.1',
        'x-amz-target': target,
    }

    signed = sigv4({
        'method': 'POST',
        'url': url,
        'headers': headers,
        'body': body,
        'service': service,
        'region': auth['region'],
        'keyid': auth['keyid'],
        'secret': auth['secret'],
        'session': auth['session'],
        'datetime': awsnow(),
    })

    allheaders = dict(headers)
    allheaders.update(signed)

    return fetchjson('POST', url, allheaders, body)


def awsmiss(body, types):
    """Does this AWS error body name one of the not-found types? Those are
    a miss; every other failure is a store that could not answer."""
    errtype = body.get('__type') if isinstance(body, dict) else None
    if not isinstance(errtype, str):
        errtype = ''
    return any(name in errtype for name in types)


class AwssecretsProvider(Provider):
    """AWS Secrets Manager.

    `api.token` reads the secret named `api` (the vaultref path, so
    `db.pass.main` reads `db/pass`) and takes the `token` field of its
    JSON SecretString - the AWS idiom of one JSON map per secret. A
    SecretString that is not JSON is the value itself, under the
    conventional field `value`. Requests are SigV4-signed in-tree; see
    sigv4.py.
    """

    def __init__(self, options=None):
        self.opts = options or {}

    def lookup(self, name):
        ref = vaultref(name)

        status, body = awscall(
            self.opts, 'secretsmanager', 'secretsmanager.GetSecretValue',
            {'SecretId': ref['path']},
        )

        if 400 == status and awsmiss(body, ['ResourceNotFoundException']):
            return None

        if 200 != status:
            raise SekretoError('sekreto: aws secretsmanager error: ' + str(status))

        text = (body or {}).get('SecretString')

        if not isinstance(text, str):
            # A binary secret has no fields to address; only the conventional
            # `value` field can mean "the bytes themselves".
            binary = (body or {}).get('SecretBinary')
            if isinstance(binary, str) and 'value' == ref['field']:
                # validate=True: b64decode silently SKIPS characters
                # outside the alphabet, so a corrupted payload decoded to
                # plausible-looking bytes that were then returned as the
                # secret. A store that answered incoherently is an error,
                # never a miss.
                try:
                    return base64.b64decode(binary, validate=True).decode('utf8')
                except Exception:
                    raise SekretoError('sekreto: aws secretsmanager: undecodable secret')
            return None

        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = None

        if isinstance(parsed, dict):
            value = parsed.get(ref['field'])
            return None if value is None else str(value)

        # A plain-string secret is the whole value; it has no named fields.
        return text if 'value' == ref['field'] else None

    def describe(self):
        # Config only, never the environment: describe() feeds the spec's
        # sources group, which must answer the same everywhere.
        return 'awssecrets:' + (self.opts.get('region') or '')


class AwsparamsProvider(Provider):
    """AWS SSM Parameter Store.

    `db.pass.main` reads the parameter `/db/pass/main` (under an optional
    prefix path), decrypted. Parameter Store carries flat strings, so
    there is no field indirection.
    """

    def __init__(self, options=None):
        self.opts = options or {}

    def lookup(self, name):
        status, body = awscall(self.opts, 'ssm', 'AmazonSSM.GetParameter', {
            'Name': awsparam(name, self.opts.get('prefix')),
            'WithDecryption': True,
        })

        if 400 == status and awsmiss(body, ['ParameterNotFound']):
            return None

        if 200 != status:
            raise SekretoError('sekreto: aws ssm error: ' + str(status))

        value = ((body or {}).get('Parameter') or {}).get('Value')
        return None if value is None else str(value)

    def describe(self):
        return 'awsparams:' + (self.opts.get('region') or '') + (self.opts.get('prefix') or '')


# The two plugins: the `awssecrets` and `awsparams` provider kinds, as
# voxgig/plugin definitions.
awssecrets = providerplugin('awssecrets', AwssecretsProvider)
awsparams = providerplugin('awsparams', AwsparamsProvider)

__all__ = ['AwssecretsProvider', 'AwsparamsProvider', 'awssecrets', 'awsparams', 'sigv4']
