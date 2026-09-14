<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Version.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Versions and ranges (§11.2).
 *
 * TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
 * concrete version. A requirement declares `range`. A requirement is
 * satisfied when the names match, the `match` passes, and:
 *
 *   the provider's `version` falls inside the requirement's `range`.
 *
 * That is the whole rule. There is no third field and no second
 * comparison - an earlier draft added a provider-side `compat` range,
 * which left three values and no statement of how they combine, and three
 * defensible readings of one declaration is worse than the ambiguity it
 * was introduced to fix.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

const VERSION_RE = '/\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z/';

/**
 * A COMPONENT IS BOUNDED, and the bound is the model's, not the host
 * language's. PHP's ints are 64-bit and JavaScript's stop being exact past
 * 2**53, so `9223372036854775808.0.0` parsed to one value here and a
 * rounded one there. 2**31-1 is the smallest bound every target language
 * holds exactly, which makes it the model's.
 */
const COMPONENT_MAX = 2147483647;

/**
 * PHP's `(int)` SATURATES at PHP_INT_MAX rather than raising, so a
 * component of twenty digits arrives as 9223372036854775807 - still above
 * COMPONENT_MAX, so the bound check fires on the saturated value exactly
 * as it does on ruby's exact bignum. A LENGTH GUARD ON THE DIGITS WOULD BE
 * DEAD CODE: saturation cannot land below the bound, so nothing over-long
 * reaches the comparison and survives it.
 */
function component(string $digits, string $whole, string $field): int
{
    // COMPARE THE DIGITS, NOT THE CAST. PHP casts a numeric string wider
    // than PHP_INT_MAX to ZERO rather than saturating at it, so
    // `(int)$digits > COMPONENT_MAX` is FALSE for a thousand nines and the
    // component silently becomes 0 - a syntactically valid but wildly
    // oversized version accepted as `0.0.0`. Every other port guards this
    // explicitly (go's `Atoi` errors, rust's `parse` errors, java and
    // kotlin parse through a big integer, javascript gets `Infinity`), and
    // go's comment records the same trap with a louder failure.
    //
    // The regex admits only `\d+`, so the digits carry no sign and no
    // point: with leading zeros stripped, LONGER IS LARGER and equal
    // lengths compare lexicographically. `strcmp` rather than `>` so the
    // answer does not depend on PHP's numeric-string comparison, which is
    // the rule that caused the problem in the first place.
    $trimmed = ltrim($digits, '0');
    $bound = (string)COMPONENT_MAX;
    if (strlen($trimmed) > strlen($bound)
        || (strlen($trimmed) === strlen($bound) && strcmp($trimmed, $bound) > 0)) {
        fail_with('plugin_bad_range',
                  'version component out of range in ' . $whole . ': ' . $digits,
                  [$field => $whole]);
    }
    return (int)$digits;
}

/**
 * Two forms and no more (§11.2):
 *
 *   '2.1'    >= 2.1.0 and < 3.0.0
 *   '~2.1'   >= 2.1.0 and < 2.2.0
 *
 * @param mixed $range
 * @return array{lo:int[],hi:int[]}
 */
function parse_range($range): array
{
    if (!is_string($range) || '' === $range) {
        fail_with('plugin_bad_range', 'invalid range: ' . Util::json($range),
                  ['range' => $range]);
    }

    $tilde = str_starts_with($range, '~');
    $body = $tilde ? substr($range, 1) : $range;
    $m = [];
    if (1 !== preg_match(VERSION_RE, $body, $m)) {
        fail_with('plugin_bad_range', 'invalid range: ' . $range,
                  ['range' => $range]);
    }

    $major = component($m[1], $range, 'range');
    $minor = ($m[2] ?? '') === '' ? 0 : component($m[2], $range, 'range');
    $patch = ($m[3] ?? '') === '' ? 0 : component($m[3], $range, 'range');

    $lo = [$major, $minor, $patch];
    $hi = $tilde ? [$major, $minor + 1, 0] : [$major + 1, 0, 0];
    return ['lo' => $lo, 'hi' => $hi];
}

/**
 * @param mixed $version
 * @return int[]
 */
function parse_version($version): array
{
    if (!is_string($version)) {
        fail_with('plugin_bad_range', 'invalid version: ' . Util::json($version),
                  ['version' => $version]);
    }
    $m = [];
    if (1 !== preg_match(VERSION_RE, $version, $m)) {
        fail_with('plugin_bad_range', 'invalid version: ' . $version,
                  ['version' => $version]);
    }
    return [
        component($m[1], $version, 'version'),
        ($m[2] ?? '') === '' ? 0 : component($m[2], $version, 'version'),
        ($m[3] ?? '') === '' ? 0 : component($m[3], $version, 'version'),
    ];
}

/** The one satisfaction predicate: lo <= version < hi. */
function satisfies($version, $range): bool
{
    $v = parse_version($version);
    $r = parse_range($range);
    return version_cmp($v, $r['lo']) >= 0 && version_cmp($v, $r['hi']) < 0;
}

/**
 * satisfies for the internal callers that treat an unparseable version or
 * range as "does not satisfy" - Capability and Graph, both of which run
 * over data the corpus has already admitted.
 */
function satisfiesq($version, $range): bool
{
    try {
        return satisfies($version, $range);
    } catch (PluginError $e) {
        return false;
    }
}

/**
 * @param int[] $a
 * @param int[] $b
 */
function version_cmp(array $a, array $b): int
{
    for ($i = 0; $i < 3; $i++) {
        $x = $a[$i] ?? 0;
        $y = $b[$i] ?? 0;
        if ($x !== $y) {
            return $x < $y ? -1 : 1;
        }
    }
    return 0;
}
