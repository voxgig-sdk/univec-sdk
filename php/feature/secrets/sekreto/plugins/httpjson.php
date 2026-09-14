<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/httpjson.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * The HTTP half of every plugin that speaks to a store over the wire, in
 * one place and OUTSIDE the core: a chain of built-ins never requires this
 * file.
 *
 * One JSON round-trip, bounded in time and in size, refusing redirects and
 * ignoring proxies. A port of typescript/plugins/httpjson.ts.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto\Plugins;

require_once __DIR__ . '/../src/Sekreto.php';

use Voxgig\Sekreto\SekretoError;

/**
 * One JSON round-trip, returning [status, decoded-json-or-null].
 *
 * A 404 is a normal answer here, not a failure: it means the store does not
 * hold this secret. Network failure is always an error - an unreachable
 * store is a store that could not answer. Uses the stream wrapper so that
 * no extension beyond the default build is required.
 *
 * @param array<int, string> $headers
 * @return array{0: int, 1: mixed}
 */
function fetchjson(string $method, string $url, array $headers, ?string $body = null): array
{
    $options = [
        'method' => $method,
        'header' => implode("\r\n", $headers),
        // Read the body of an error response rather than throwing it away.
        'ignore_errors' => true,
        'timeout' => 10,
        'follow_location' => 0,
        'max_redirects' => 0,
    ];

    if (null !== $body) {
        $options['content'] = $body;
    }

    $context = stream_context_create(['http' => $options]);

    // maxlen + 1: an endless body would otherwise be accumulated in memory
    // until the deadline, which on a loopback or datacentre link is
    // gigabytes. One byte over the bound is enough to know it was exceeded.
    $text = @file_get_contents($url, false, $context, 0, HTTP_MAXBODY + 1);

    if (false === $text) {
        throw new SekretoError('sekreto: cannot reach ' . explode('?', $url)[0]);
    }

    // An endless body is a store that could not answer, so this raises
    // rather than returning a miss - the latter would fall through to a
    // weaker store on an attacker's cue.
    if (HTTP_MAXBODY < strlen($text)) {
        throw new SekretoError('sekreto: oversized response from ' . explode('?', $url)[0]);
    }

    $status = 0;
    foreach ($http_response_header ?? [] as $line) {
        if (1 === preg_match('#^HTTP/\S+\s+(\d+)#', $line, $match)) {
            $status = (int) $match[1];
        }
    }

    $parsed = json_decode($text, true);

    if (null === $parsed && JSON_ERROR_NONE !== json_last_error()) {
        // A success status promised JSON; a body that does not parse means
        // the store could not answer coherently, and treating it as a miss
        // would fall through to a weaker store. Error statuses may carry
        // any body - they are decided on status alone.
        if (200 === $status) {
            throw new SekretoError('sekreto: malformed response from ' . explode('?', $url)[0]);
        }
        $parsed = null;
    }

    return [$status, $parsed];
}

/**
 * GET a URL, returning [status, decoded-json-or-null].
 *
 * @param array<int, string> $headers
 * @return array{0: int, 1: mixed}
 */
function httpget(string $url, array $headers): array
{
    return fetchjson('GET', $url, $headers);
}

/**
 * How much of a response body will be read before the store is treated as
 * having answered incoherently. Ports carry the same bound.
 *
 * Far above anything real - the largest legitimate payload this library
 * fetches is Doppler's whole-config download, measured in kilobytes. A bound
 * is needed because the TIMEOUT is not one: ten seconds on a loopback or
 * datacentre link is gigabytes, and the body is accumulated in memory before
 * it is parsed. This runs on an application's startup path, so the failure is
 * the application never starting.
 */
const HTTP_MAXBODY = 8 * 1024 * 1024;
