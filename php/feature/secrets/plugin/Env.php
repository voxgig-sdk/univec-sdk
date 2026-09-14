<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Env.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Environment overrides (§9.5) - level 7 of the ladder.
 *
 * One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
 *
 *   VOXGIG_PLUGIN_PROFILE            the profile name
 *   VOXGIG_PLUGIN_<REF>_<PATH>       one option
 *   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
 *
 * THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
 * OTHERWISE. Ref and path are upper-snake with `$` -> `__` and `.` -> `_`.
 * But `_` is legal in a name and in a tag, and the mapping folds case, so
 * `retry$fast` and `retry__fast` both encode to `RETRY__FAST`.
 *
 * Rather than restrict a grammar the rest of the stack already uses, the
 * host DETECTS THE COLLISION: it encodes every ref it holds, and a key two
 * refs claim is `plugin_env_ambiguous`, naming both.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

const ENV_PREFIX = 'VOXGIG_PLUGIN_';

/** `retry$fast` -> `RETRY__FAST`. */
function encode_ref(string $ref): string
{
    return strtoupper(str_replace(['$', '.'], ['__', '_'], $ref));
}

/**
 * @param array<string,mixed>|null $input
 * @return array<string,mixed>
 */
function apply_env(?array $input): array
{
    $input = $input ?? [];
    $env = $input['env'] ?? [];
    $refs = [];
    foreach ($input['refs'] ?? [] as $r) {
        $refs[] = canon_ref($r);
    }
    $reserved = $input['reserved'] ?? [];
    $out = ['options' => [], 'active' => [], 'inactive' => []];

    // Encode every ref the host holds, and refuse a key that two of them
    // claim. Done up front so the collision is reported even when no
    // environment variable exercises it - a latent ambiguity is still an
    // ambiguity, and finding it at deploy time is the failure this exists
    // to prevent.
    $byencoded = [];
    foreach ($refs as $r) {
        $e = encode_ref($r);
        if (!array_key_exists($e, $byencoded)) {
            $byencoded[$e] = [];
        }
        $byencoded[$e][] = $r;
    }
    foreach (Util::sortedkeys($byencoded) as $e) {
        if (count($byencoded[$e]) <= 1) {
            continue;
        }
        $pair = Util::sortstrings($byencoded[$e]);
        fail_with('plugin_env_ambiguous',
                  'refs collide in the environment encoding as ' . $e . ': '
                  . implode(', ', $pair),
                  ['encoded' => $e, 'refs' => $pair]);
    }

    // Longest encoded ref first, so `retry$fast` wins over `retry` on
    // `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    $encoded = Util::stable_sort_by(Util::sortedkeys($byencoded),
        static function ($e) {
            return [-strlen($e)];
        });

    foreach (Util::sortedkeys($env) as $key) {
        if (!str_starts_with($key, ENV_PREFIX)) {
            continue;
        }

        $rest = substr($key, strlen(ENV_PREFIX));

        if ('PROFILE' === $rest) {
            $out['profile'] = $env[$key];
            continue;
        }

        if ('ACTIVE' === $rest || 'INACTIVE' === $rest) {
            foreach (env_split($env[$key]) as $raw) {
                $ref = canon_ref($raw);
                // The reservation covers EVERY input layer (§9.1).
                // VOXGIG_PLUGIN_INACTIVE=station is easier to set than
                // editing a config file, and INACTIVE has the final word -
                // so guarding documents alone would leave the one lever
                // this mechanism exists to deny wide open.
                env_checkreserved($ref, $reserved);
                $out['ACTIVE' === $rest ? 'active' : 'inactive'][] = $ref;
            }
            continue;
        }

        $enc = null;
        foreach ($encoded as $e) {
            if ($rest === $e || str_starts_with($rest, $e . '_')) {
                $enc = $e;
                break;
            }
        }
        if (null === $enc) {
            continue;              // not for any ref this host holds
        }

        $ref = $byencoded[$enc][0];
        env_checkreserved($ref, $reserved);

        if ($rest === $enc) {
            continue;              // a ref with no path sets nothing
        }

        $path = explode('_', strtolower(substr($rest, strlen($enc) + 1)));

        if (!isset($out['options'][$ref]) || !is_array($out['options'][$ref])) {
            $out['options'][$ref] = [];
        }
        // A PHP ARRAY IS A VALUE, so walking into one to write a nested
        // key needs an explicit reference - `$node = $out['options'][$ref]`
        // would build the path in a copy and discard it. `unset` at the
        // end releases the alias, because the next iteration's `=&`
        // rebinds the name but any plain assignment through it would not.
        $node = &$out['options'][$ref];
        foreach (array_slice($path, 0, -1) as $step) {
            if (!isset($node[$step]) || !is_array($node[$step])) {
                $node[$step] = [];
            }
            $node = &$node[$step];
        }
        $node[$path[count($path) - 1]] = env_parsevalue($env[$key]);
        unset($node);
    }

    return $out;
}

/**
 * @param mixed $value
 * @return string[]
 */
function env_split($value): array
{
    $out = [];
    foreach (explode(',', (string)$value) as $part) {
        $part = trim($part);
        if ('' !== $part) {
            $out[] = $part;
        }
    }
    return $out;
}

/**
 * @param string[] $reserved
 */
function env_checkreserved(string $ref, array $reserved): void
{
    if (empty($reserved)) {
        return;
    }
    if (!in_array(refname($ref), $reserved, true)) {
        return;
    }
    fail_with('plugin_ref_reserved', 'ref is reserved by the host: ' . $ref,
              ['ref' => $ref]);
}

/**
 * Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
 * `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
 * looks like rather than a parse error.
 *
 * PHP's `json_decode` accepts a bare scalar at the top level, so no quirks
 * flag is needed; what it does NOT do is tell an invalid document from a
 * valid `null`, which is why the error code is read rather than the
 * result.
 *
 * @param mixed $value
 * @return mixed
 */
function env_parsevalue($value)
{
    if (!is_string($value)) {
        return $value;
    }
    $parsed = json_decode($value, true);
    return JSON_ERROR_NONE === json_last_error() ? $parsed : $value;
}
