# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/plugins/httpjson.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The HTTP half of every plugin that speaks to a store over the wire, in
# one place and OUTSIDE the core: a chain of built-ins never imports this
# module. One JSON round-trip, bounded in time and in size, refusing
# redirects and ignoring proxies; and the small helpers every store client
# needs. A port of typescript/plugins/httpjson.ts.

import json
import urllib.error
import urllib.parse
import urllib.request

from ..sekreto import SekretoError


# How long any single vault round-trip may take before it is treated as
# unreachable, in seconds. Ports carry the same bound.
_HTTP_TIMEOUT = 10

# How much of a response body will be read before the store is treated as
# having answered incoherently. Ports carry the same bound.
#
# Far above anything real - the largest legitimate payload this library
# fetches is Doppler's whole-config download, measured in kilobytes. A bound
# is needed because the TIMEOUT is not one: ten seconds on a loopback or
# datacentre link is gigabytes, and the body is accumulated in memory before
# it is parsed. This runs on an application's startup path, so the failure is
# the application never starting.
_HTTP_MAXBODY = 8 * 1024 * 1024


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect handler that refuses to follow: a vault API never
    legitimately redirects, and following one would resend the vault token
    to the redirect's host."""

    def redirect_request(self, *args, **kwargs):
        return None


# A secrets client dials the address it was configured with and nowhere
# else. urllib installs a ProxyHandler from the environment by default, and
# its proxy resolution does NOT exempt loopback - so with http_proxy set,
# `X-Vault-Token` for a local dev vault went, in the clear, to whatever that
# variable named. checkaddr permits plaintext to loopback precisely because
# nothing leaves the machine; an environment variable it cannot see must not
# be able to make that false. An empty ProxyHandler turns the whole
# mechanism off.
_opener = urllib.request.build_opener(_NoRedirect, urllib.request.ProxyHandler({}))


def fetchjson(method, url, headers, body=None):
    """One JSON round-trip, returning (status, parsed-json-or-None).

    A 404 is a normal answer here, not an exception: callers decide on
    status. Network failure is always an error - an unreachable store is a
    store that could not answer.
    """
    data = None if body is None else body.encode('utf8')
    request = urllib.request.Request(url, data=data, headers=headers, method=method)

    try:
        # No redirects (a followed one carries X-Vault-Token to the target,
        # which checkaddr cannot see) and a bounded wait (an accepted-but-
        # silent endpoint must not hang the caller forever). A 3xx surfaces
        # as an HTTPError below and is treated as a store error.
        with _opener.open(request, timeout=_HTTP_TIMEOUT) as response:
            status = response.status
            raw = response.read(_HTTP_MAXBODY + 1)
    except urllib.error.HTTPError as err:
        status = err.code
        raw = err.read(_HTTP_MAXBODY + 1)
    except urllib.error.URLError as err:
        raise SekretoError(
            'sekreto: cannot reach ' + url.split('?')[0] + ': ' + str(err.reason)
        )

    # One byte over the bound is enough to know it was exceeded. An endless
    # body is a store that could not answer, so this raises rather than
    # returning a miss - the latter would fall through to a weaker store on
    # an attacker's cue.
    if _HTTP_MAXBODY < len(raw):
        raise SekretoError('sekreto: oversized response from ' + url.split('?')[0])

    text = raw.decode('utf8', 'replace')

    try:
        return status, json.loads(text)
    except ValueError:
        # A success status promised JSON; a body that does not parse means
        # the store could not answer coherently, and treating it as a miss
        # would fall through to a weaker store. Error statuses may carry
        # any body - they are decided on status alone.
        if 200 == status:
            raise SekretoError('sekreto: malformed response from ' + url.split('?')[0])
        return status, None


def urlpart(text):
    """One URL component, escaped the way encodeURIComponent does it -
    the addresses built here must match the canonical port's byte for
    byte."""
    return urllib.parse.quote(str(text), safe="-_.!~*'()")


def tonumber(value):
    """The canonical port's Number() as expiry fields need it: a number
    or numeric string converts (expires_in may arrive as a string);
    anything else becomes 0, which means "never renew"."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0
