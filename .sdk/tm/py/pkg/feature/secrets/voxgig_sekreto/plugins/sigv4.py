# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/sigv4.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# AWS Signature Version 4, hand-rolled.
#
# The AWS providers need exactly one thing from the AWS SDK - request
# signing - and taking the SDK for it would break the no-dependency rule
# that keeps ten ports honest. SigV4 is a stable, published algorithm
# built from HMAC-SHA256, which the standard library already has.
#
# `sigv4` is pure: the caller passes the timestamp, so the same input
# yields the same signature everywhere. That is what lets the shared spec
# carry known-answer cases that all ten ports must reproduce bit-for-bit,
# and lets the integration mock recompute the signature server-side.
#
# A port of typescript/plugins/sigv4.ts, which is canonical. It lives with
# the aws plugin because it is the one place the library needs
# HMAC-SHA256, and a built-in must not.

import hashlib
import hmac as hmaclib
import re
import urllib.parse


def _sha256hex(text):
    return hashlib.sha256(text.encode('utf8')).hexdigest()


def _hmac(key, text):
    return hmaclib.new(key, text.encode('utf8'), hashlib.sha256).digest()


def _uriescape(text):
    """RFC 3986 escaping, which is stricter than encodeURIComponent: AWS
    wants `!`, `'`, `(`, `)` and `*` escaped too. Only the unreserved
    characters survive, and the hex is uppercase."""
    return urllib.parse.quote(text, safe='-_.~')


def _canonicalquery(query):
    """The canonical query string: each pair RFC 3986-escaped, sorted by
    escaped key then escaped value."""
    if '' == query:
        return ''

    pairs = []
    for pair in query.split('&'):
        eq = pair.find('=')
        key = pair if -1 == eq else pair[:eq]
        value = '' if -1 == eq else pair[eq + 1:]
        pairs.append((
            _uriescape(urllib.parse.unquote(key)),
            _uriescape(urllib.parse.unquote(value)),
        ))

    pairs.sort()

    return '&'.join(key + '=' + value for key, value in pairs)


def sigv4(input):
    """Sign one request. Returns the headers to attach: authorization,
    x-amz-date, and x-amz-security-token when a session token was given."""
    url = urllib.parse.urlsplit(input['url'])

    datetime = input['datetime']
    date = datetime[:8]
    body = input.get('body') or ''
    session = input.get('session')

    # Every header that will be signed: the caller's extras, plus host and
    # x-amz-date (and the session token when present), lower-cased and
    # trimmed the way the canonical form requires.
    # Canonical header values are trimmed AND internally collapsed -
    # AWS folds sequential whitespace to one space before signing, so a
    # header like "a  b" must sign as "a b" or the service refuses it.
    headers = {}
    for key, value in (input.get('headers') or {}).items():
        headers[key.lower()] = re.sub(r'\s+', ' ', str(value).strip())
    headers['host'] = url.netloc
    headers['x-amz-date'] = datetime
    if session:
        headers['x-amz-security-token'] = session

    names = sorted(headers.keys())
    canonicalheaders = ''.join(name + ':' + headers[name] + '\n' for name in names)
    signedheaders = ';'.join(names)

    canonicalrequest = '\n'.join([
        input['method'].upper(),
        url.path or '/',
        _canonicalquery(url.query),
        canonicalheaders,
        signedheaders,
        _sha256hex(body),
    ])

    scope = date + '/' + input['region'] + '/' + input['service'] + '/aws4_request'

    stringtosign = '\n'.join([
        'AWS4-HMAC-SHA256',
        datetime,
        scope,
        _sha256hex(canonicalrequest),
    ])

    kdate = _hmac(('AWS4' + input['secret']).encode('utf8'), date)
    kregion = _hmac(kdate, input['region'])
    kservice = _hmac(kregion, input['service'])
    ksigning = _hmac(kservice, 'aws4_request')
    signature = hmaclib.new(
        ksigning, stringtosign.encode('utf8'), hashlib.sha256
    ).hexdigest()

    out = {
        'authorization': 'AWS4-HMAC-SHA256 Credential=' + input['keyid'] + '/' + scope
        + ', SignedHeaders=' + signedheaders + ', Signature=' + signature,
        'x-amz-date': datetime,
    }

    if session:
        out['x-amz-security-token'] = session

    return out
