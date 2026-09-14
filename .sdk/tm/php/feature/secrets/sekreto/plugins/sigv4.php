<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/sigv4.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * AWS Signature Version 4, hand-rolled.
 *
 * The AWS providers need exactly one thing from the AWS SDK - request
 * signing - and taking the SDK for it would break the no-dependency rule
 * that keeps ten ports honest. SigV4 is a stable, published algorithm
 * built from HMAC-SHA256, which PHP's standard hash extension already has.
 *
 * `sigv4` is pure: the caller passes the timestamp, so the same input
 * yields the same signature everywhere. That is what lets the shared spec
 * carry known-answer cases that all ten ports must reproduce bit-for-bit,
 * and lets the integration mock recompute the signature server-side.
 *
 * IT LIVES WITH THE AWS PLUGIN, not in the core. Signing is the sharpest
 * instance of the line the split draws: the core of no port imports a hash
 * function, and only a program that names an AWS kind requires this file.
 *
 * A port of typescript/plugins/sigv4.ts, which is canonical.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto\Plugins;

/**
 * RFC 3986 escaping, which is stricter than PHP's urlencode: AWS wants
 * `!`, `'`, `(`, `)` and `*` escaped too - which is exactly what
 * rawurlencode does, with the uppercase hex the canonical form requires.
 */
function uriescape(string $text): string
{
    return rawurlencode($text);
}

/**
 * The canonical query string: each pair RFC 3986-escaped, sorted by
 * escaped key then escaped value.
 */
function canonicalquery(string $query): string
{
    if ('' === $query) {
        return '';
    }

    $pairs = [];

    foreach (explode('&', $query) as $pair) {
        $eq = strpos($pair, '=');
        $key = false === $eq ? $pair : substr($pair, 0, $eq);
        $value = false === $eq ? '' : substr($pair, $eq + 1);
        $pairs[] = [uriescape(rawurldecode($key)), uriescape(rawurldecode($value))];
    }

    usort($pairs, function (array $left, array $right) {
        if ($left[0] !== $right[0]) {
            return strcmp($left[0], $right[0]);
        }
        return strcmp($left[1], $right[1]);
    });

    return implode('&', array_map(fn(array $pair) => $pair[0] . '=' . $pair[1], $pairs));
}

/**
 * Sign one request. Returns the headers to attach: authorization,
 * x-amz-date, and x-amz-security-token when a session token was given.
 *
 * Input keys: method, url, headers?, body?, service, region, keyid,
 * secret, session?, datetime (YYYYMMDDTHHMMSSZ).
 *
 * @param array<string, mixed> $input
 * @return array<string, string>
 */
function sigv4(array $input): array
{
    $url = parse_url((string) $input['url']) ?: [];

    $date = substr((string) $input['datetime'], 0, 8);
    $body = (string) ($input['body'] ?? '');

    // The host as a URL object reports it: including the port only when it
    // is not the scheme's default.
    $scheme = strtolower((string) ($url['scheme'] ?? ''));
    $host = (string) ($url['host'] ?? '');
    $port = $url['port'] ?? null;
    if (
        null !== $port &&
        !('https' === $scheme && 443 === $port) &&
        !('http' === $scheme && 80 === $port)
    ) {
        $host .= ':' . $port;
    }

    // Every header that will be signed: the caller's extras, plus host and
    // x-amz-date (and the session token when present), lower-cased and
    // trimmed the way the canonical form requires.
    // Canonical header values are trimmed AND internally collapsed -
    // AWS folds sequential whitespace to one space before signing, so a
    // header like "a  b" must sign as "a b" or the service refuses it.
    $headers = [];
    foreach ($input['headers'] ?? [] as $key => $value) {
        $headers[strtolower((string) $key)] = preg_replace('/\s+/', ' ', trim((string) $value));
    }
    $headers['host'] = $host;
    $headers['x-amz-date'] = (string) $input['datetime'];
    if (!empty($input['session'])) {
        $headers['x-amz-security-token'] = (string) $input['session'];
    }

    $names = array_keys($headers);
    sort($names);
    $canonicalheaders = implode(
        '',
        array_map(fn(string $name) => $name . ':' . $headers[$name] . "\n", $names)
    );
    $signedheaders = implode(';', $names);

    $path = (string) ($url['path'] ?? '');

    $canonicalrequest = implode("\n", [
        strtoupper((string) $input['method']),
        '' === $path ? '/' : $path,
        canonicalquery((string) ($url['query'] ?? '')),
        $canonicalheaders,
        $signedheaders,
        hash('sha256', $body),
    ]);

    $scope = $date . '/' . $input['region'] . '/' . $input['service'] . '/aws4_request';

    $stringtosign = implode("\n", [
        'AWS4-HMAC-SHA256',
        $input['datetime'],
        $scope,
        hash('sha256', $canonicalrequest),
    ]);

    $kdate = hash_hmac('sha256', $date, 'AWS4' . $input['secret'], true);
    $kregion = hash_hmac('sha256', (string) $input['region'], $kdate, true);
    $kservice = hash_hmac('sha256', (string) $input['service'], $kregion, true);
    $ksigning = hash_hmac('sha256', 'aws4_request', $kservice, true);
    $signature = hash_hmac('sha256', $stringtosign, $ksigning);

    $out = [
        'authorization' => 'AWS4-HMAC-SHA256 Credential=' . $input['keyid'] . '/' . $scope
            . ', SignedHeaders=' . $signedheaders
            . ', Signature=' . $signature,
        'x-amz-date' => (string) $input['datetime'],
    ];

    if (!empty($input['session'])) {
        $out['x-amz-security-token'] = (string) $input['session'];
    }

    return $out;
}
