# VENDORED: @voxgig/sekreto 0.2.0 (python/voxgig_sekreto/addr.py)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
# The plaintext-address guard, in the core because it is pure - a handful
# of string steps, no socket - and because it is on the spec: every port
# answers the same for every address in spec/def/store.aon. The plugins
# that dial an address call `checkaddr` before they do.
#
# A port of typescript/src/provider/addr.ts.

from .sekreto import SekretoError


def safeaddr(addr):
    """An address with any userinfo replaced by `[redacted]`, for messages.

    Every refusal below names the address it refused, and one of them fires
    precisely because the address carries a credential - so printing it
    verbatim wrote the password to stderr and into the logs. It cannot be
    cleaned up afterwards either: that password was never resolved as a
    secret, so `redact` has never seen it and never will. The host is what a
    reader needs to identify which chain entry is at fault; the userinfo is
    not.
    """
    mark = addr.find('://')
    if -1 == mark:
        return addr

    rest = addr[mark + 3:]
    end = len(rest)
    for ch in ('/', '?', '#'):
        at = rest.find(ch)
        if -1 != at and at < end:
            end = at
    authority = rest[:end]

    at = authority.rfind('@')
    if -1 == at:
        return addr

    return addr[:mark + 3] + '[redacted]' + addr[mark + 3 + at:]


def checkaddr(addr):
    """Refuse to send a Vault token in the clear.

    Vault's API is HTTPS in any real deployment; plaintext is a dev-mode
    convenience. Sending `X-Vault-Token` over http to anything but the local
    machine puts both the token and the secret it fetches on the wire for
    anyone on the path, so sekreto will not do it. Loopback stays allowed:
    that is `vault server -dev` and this repo's own test harness.

    The address is read by hand, in the same handful of steps in every port,
    rather than by each platform's URL parser. That is deliberate. Twelve
    parsers disagree about malformed input - where userinfo ends, whether
    `0177.0.0.1` is loopback, what an unclosed bracket means - and a check
    that answers differently in different ports is not a check.

    The rule this parse obeys, and the reason it can be trusted: it is never
    more permissive than the HTTP client that will dial the address. It ends
    the authority at `/`, `?` or `#` only, so a client that also breaks on
    `\\` (WHATWG does) can only ever see a SHORTER host than this does. It
    refuses userinfo outright rather than locating its end. It compares the
    host literally, so a numeric form no parser here agrees on is refused
    rather than guessed at.
    """
    if addr.startswith('https://'):
        scheme = 'https://'
    elif addr.startswith('http://'):
        scheme = 'http://'
    else:
        raise SekretoError('sekreto: not an http(s) address: ' + safeaddr(addr))

    rest = addr[len(scheme):]
    end = len(rest)
    for mark in ('/', '?', '#'):
        at = rest.find(mark)
        if -1 != at and at < end:
            end = at
    authority = rest[:end]

    # Userinfo is refused outright rather than parsed around, and on https as
    # well as http. No store this library speaks authenticates by userinfo -
    # they take a token or a signature - so an address carrying one is a
    # mistake at best. At worst it is the attack this whole function exists
    # to stop: `http://localhost:8200@evil.example.com/` is a request to
    # evil.example.com that reads, to anything that splits the authority on
    # ':', as loopback.
    if '@' in authority:
        raise SekretoError(
            'sekreto: refusing an address with embedded credentials: ' + safeaddr(addr)
        )

    # An opening bracket with no closing one is not an address at all.
    if authority.startswith('[') and ']' not in authority:
        raise SekretoError('sekreto: not a valid http(s) address: ' + safeaddr(addr))

    if 'https://' == scheme:
        return

    # A bracketed IPv6 literal keeps its brackets. Splitting the authority on
    # the first colon yields '[', so `http://[::1]:8200` could never match -
    # which made the '[::1]' entry below unreachable, and refused a
    # legitimate local vault.
    if authority.startswith('['):
        host = authority[:authority.index(']') + 1]
    else:
        host = authority.split(':')[0]

    if host.lower() in ('localhost', '127.0.0.1', '::1', '[::1]'):
        return

    raise SekretoError(
        'sekreto: refusing to send a token in plaintext to ' + safeaddr(addr)
        + ' (use https)'
    )
