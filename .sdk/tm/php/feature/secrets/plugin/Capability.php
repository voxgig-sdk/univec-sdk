<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Capability.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Capabilities (§11.1).
 *
 * A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
 * dependency on something that can do the job, and which instance is doing
 * it is exactly the configuration detail a plugin must not care about.
 *
 * But A BINDING IS TO AN INSTANCE, not to a capability, which is what
 * decides behaviour when the bound provider leaves while another match
 * remains.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

/**
 * Rank the matching live providers and return them best-first: highest
 * `version`, then LOWEST `priority` (default 0), then declaration position
 * `pos` ascending.
 *
 * `priority` is a field on the capability rather than §7's `order` band,
 * because bands live on POINT BINDINGS: a provider may have several
 * bindings with different bands, or none at all, so a rank reaching for
 * one would be undefined in the common case.
 *
 * Without a total rank, "any provider satisfies" is true of the GRAPH and
 * useless to the PLUGIN - two ports could bind different `store`
 * instances, both resolve green, and behave differently, which is
 * precisely the divergence a shared corpus exists to catch.
 *
 * @param array<string,mixed> $req
 * @param array<int,array<string,mixed>> $candidates
 * @return array<int,array<string,mixed>>
 */
function resolve_capability(array $req, array $candidates): array
{
    $hits = [];
    foreach ($candidates as $c) {
        if (matches($req, $c['provides'] ?? [])) {
            $hits[] = $c;
        }
    }
    return Util::stable_sort_by($hits, static function ($c) {
        return rank_key($c);
    });
}

/**
 * @param array<string,mixed> $cand
 * @return array<int,mixed>
 */
function rank_key(array $cand): array
{
    $prov = $cand['provides'] ?? [];
    $version = $prov['version'] ?? null;
    // An ABSENT version sorts LAST, whatever the other is - "no version"
    // loses to every version rather than being read as 0.0.0. The leading
    // flag is what expresses that in a sort KEY rather than a comparator.
    $parts = null === $version ? [0, 0, 0] : version_parts($version);
    return [
        null === $version ? 1 : 0,
        array_map(static function ($n) { return -$n; }, $parts),
        $prov['priority'] ?? 0,
        $cand['pos'] ?? 0,
    ];
}

/**
 * @param array<string,mixed> $req
 * @param array<string,mixed> $prov
 */
function matches(array $req, array $prov): bool
{
    if (($req['name'] ?? null) !== ($prov['name'] ?? null)) {
        return false;
    }

    if (null !== ($req['range'] ?? null)) {
        if (null === ($prov['version'] ?? null)) {
            return false;
        }
        if (!satisfiesq($prov['version'], $req['range'])) {
            return false;
        }
    }

    // `match` is checked against the provider's `attrs`, key by key. A key
    // the provider does not carry is a miss, not a pass: a requirement
    // asking for `transactional: true` must not be satisfied by a provider
    // that never said.
    if (null !== ($req['match'] ?? null)) {
        $attrs = $prov['attrs'] ?? [];
        foreach ($req['match'] as $k => $want) {
            if (!is_array($attrs) || !array_key_exists($k, $attrs)) {
                return false;
            }
            if (!matchvalue($want, $attrs[$k])) {
                return false;
            }
        }
    }

    return true;
}

/**
 * PARTIAL MATCH, RECURSING INTO MAPS (§11.1).
 *
 * §11.1 defines `match` as "a partial match against `attrs`, with exactly
 * the semantics voxgig/struct and the omni corpus already define for
 * `match` - every leaf in the requirement must be present and equal in the
 * capability, keys not mentioned are not checked."
 *
 * Equality is by JSON TYPE as well as value: `transactional: 1` does not
 * satisfy `transactional: true`. PHP NEEDS THE GUARD RUBY DOES NOT -
 * `true == 1` is true here, and `0 == ''` was true before PHP 8 - so every
 * leaf goes through `samescalar`, which compares booleans only to
 * booleans and null only to null while still reading JSON's one number
 * type across PHP's int and float.
 *
 * A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
 *
 * @param mixed $want
 * @param mixed $got
 */
function matchvalue($want, $got): bool
{
    if (is_array($want)) {
        if (!is_array($got)) {
            return false;
        }
        // AN EMPTY `$want` IS UNDECIDABLE HERE, AND FAILS CLOSED. `[]`
        // is both the empty map and the empty list in PHP - not merely
        // after `json_decode`, but in the language: an array literal
        // cannot say which it is (php/AGENTS.md). So php sees ONE input
        // where the canonical sees two, and the canonical's answers for
        // the two disagree on every non-empty `$got`: `{}` accepts any
        // map, `[]` accepts only another empty list.
        //
        // Taking the shape from `$got` was tried and is worse. It made
        // `match: {modes: []}` accept `modes: {write: true}`, which the
        // canonical rejects - and a false ACCEPT binds a capability that
        // does not meet the requirement, where a false REJECT is a
        // visible resolution failure.
        //
        // Matching only an empty capability puts the error on the safe
        // side: against a NON-EMPTY `$got` php never accepts what the
        // canonical would reject, and over-rejects in exactly one case -
        // an empty requirement against a non-empty map, where reading
        // `[]` as `{}` would have said yes. Empty against empty stays
        // true, which is the canonical's answer whenever the two shapes
        // agree; the crossed shapes it would reject are not a thing a
        // PHP caller can express on either side.
        if ([] === $want) {
            return [] === $got;
        }
        $wantmap = !array_is_list($want);
        if ($wantmap) {
            foreach ($want as $k => $v) {
                if (!array_key_exists($k, $got) || !matchvalue($v, $got[$k])) {
                    return false;
                }
            }
            return true;
        }
        if (!array_is_list($got) || count($want) !== count($got)) {
            return false;
        }
        foreach ($want as $i => $v) {
            if (!matchvalue($v, $got[$i])) {
                return false;
            }
        }
        return true;
    }

    return samescalar($want, $got);
}

/**
 * JSON's type equality on two scalars: `===` everywhere except between two
 * numbers.
 *
 * The exception is the whole point. JSON has ONE number type and PHP has
 * two, so `1 === 1.0` is false here and true in the model - a port that
 * used `===` throughout would fail on a value that arrived through
 * arithmetic rather than through the parser. No corpus entry currently
 * mixes the two spellings, and a mutation making this branch strict
 * survives; it stays because the cost of being wrong about it is a false
 * failure in a port that did nothing wrong.
 *
 * AND THERE IS NO BOOLEAN GUARD, though `true == 1` is true in PHP. One
 * was written here first and removed: `is_int(true)` and `is_float(null)`
 * are both false, so a boolean or a null never reaches the numeric
 * comparison and falls to `===` regardless. A mutation deleting the guard
 * survived the corpus, which is what a guard that cannot fire looks like.
 *
 * @param mixed $a
 * @param mixed $b
 */
function samescalar($a, $b): bool
{
    if ((is_int($a) || is_float($a)) && (is_int($b) || is_float($b))) {
        return $a == $b;
    }
    return $a === $b;
}

/**
 * @param mixed $text
 * @return int[]
 */
function version_parts($text): array
{
    $out = [];
    foreach (explode('.', (string)$text) as $part) {
        $out[] = (int)$part;
    }
    return $out;
}
