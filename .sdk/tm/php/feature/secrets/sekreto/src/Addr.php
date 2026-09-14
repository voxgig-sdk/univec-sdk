<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/src/Addr.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Reading a store address safely: the two pure functions every plugin that
 * dials a host runs first.
 *
 * They stay in the CORE even though only plugins call them. They are
 * string work - no socket, no resolver, no platform - and the rule they
 * enforce is a property of sekreto rather than of any one store, so a
 * custom provider kind written outside this repository gets it for free.
 *
 * A port of typescript/src/addr.ts, which is canonical.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto;

require_once __DIR__ . '/Sekreto.php';

/**
 * An address with any userinfo replaced by `[redacted]`, for messages.
 *
 * Every refusal below names the address it refused, and one of them fires
 * precisely because the address carries a credential - so printing it
 * verbatim wrote the password to stderr and into the logs. It cannot be
 * cleaned up afterwards either: that password was never resolved as a
 * secret, so redact() has never seen it and never will. The host is what a
 * reader needs to identify which chain entry is at fault; the userinfo is
 * not.
 */
function safeaddr(string $addr): string
{
    $mark = strpos($addr, '://');
    if (false === $mark) {
        return $addr;
    }

    $rest = substr($addr, $mark + 3);
    $authority = substr($rest, 0, strcspn($rest, '/?#'));

    $at = strrpos($authority, '@');
    if (false === $at) {
        return $addr;
    }

    return substr($addr, 0, $mark + 3) . '[redacted]' . substr($addr, $mark + 3 + $at);
}

/**
 * Refuse to send a Vault token in the clear.
 *
 * Vault's API is HTTPS in any real deployment; plaintext is a dev-mode
 * convenience. Sending `X-Vault-Token` over http to anything but the local
 * machine puts both the token and the secret it fetches on the wire for
 * anyone on the path, so sekreto will not do it. Loopback stays allowed:
 * that is `vault server -dev` and this repo's own test harness.
 *
 * The address is read by hand, in the same handful of steps in every port,
 * rather than by each platform's URL parser. That is deliberate. Twelve
 * parsers disagree about malformed input - where userinfo ends, whether
 * `0177.0.0.1` is loopback, what an unclosed bracket means - and a check
 * that answers differently in different ports is not a check.
 *
 * The rule this parse obeys, and the reason it can be trusted: it is never
 * more permissive than the HTTP client that will dial the address. It ends
 * the authority at `/`, `?` or `#` only, so a client that also breaks on
 * `\` (WHATWG does) can only ever see a SHORTER host than this does. It
 * refuses userinfo outright rather than locating its end. It compares the
 * host literally, so a numeric form no parser here agrees on is refused
 * rather than guessed at.
 */
function checkaddr(string $addr): void
{
    if (str_starts_with($addr, 'https://')) {
        $scheme = 'https://';
    } elseif (str_starts_with($addr, 'http://')) {
        $scheme = 'http://';
    } else {
        throw new SekretoError('sekreto: not an http(s) address: ' . safeaddr($addr));
    }

    $rest = substr($addr, strlen($scheme));
    $end = strcspn($rest, '/?#');
    $authority = substr($rest, 0, $end);

    // Userinfo is refused outright rather than parsed around, and on https as
    // well as http. No store this library speaks authenticates by userinfo -
    // they take a token or a signature - so an address carrying one is a
    // mistake at best. At worst it is the attack this whole function exists
    // to stop: `http://localhost:8200@evil.example.com/` is a request to
    // evil.example.com that reads, to anything that splits the authority on
    // ':', as loopback.
    if (str_contains($authority, '@')) {
        throw new SekretoError(
            'sekreto: refusing an address with embedded credentials: ' . safeaddr($addr)
        );
    }

    // An opening bracket with no closing one is not an address at all.
    if (str_starts_with($authority, '[') && !str_contains($authority, ']')) {
        throw new SekretoError('sekreto: not a valid http(s) address: ' . safeaddr($addr));
    }

    if ('https://' === $scheme) {
        return;
    }

    // A bracketed IPv6 literal keeps its brackets. Splitting the authority on
    // the first colon yields '[', so `http://[::1]:8200` could never match -
    // which made the '[::1]' entry below unreachable, and refused a
    // legitimate local vault.
    if (str_starts_with($authority, '[')) {
        $host = substr($authority, 0, strpos($authority, ']') + 1);
    } else {
        $host = explode(':', $authority)[0];
    }

    if (in_array(strtolower($host), ['localhost', '127.0.0.1', '::1', '[::1]'], true)) {
        return;
    }

    throw new SekretoError(
        'sekreto: refusing to send a token in plaintext to ' . safeaddr($addr) . ' (use https)'
    );
}
