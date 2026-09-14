<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Config.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * The declarative document (§9): normalization, and the ten-level
 * precedence ladder.
 *
 * TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
 *
 * `normalize_config` normalizes STRUCTURE and ENTRY KEYS. It does not
 * merge options, and cannot: §9.4 makes merge behaviour a property of the
 * definition's option SHAPE, which normalization has never seen. A
 * normalizer that flattened the option layers would make `$MERGE: append`
 * unimplementable at load time, because the layers it must concatenate
 * would already be collapsed.
 *
 * `resolve_options` applies the ladder, and it is the only place that
 * knows the shape.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

const MERGE_WORDS = ['replace', 'append'];

/**
 * @param array<string,mixed>|null $input
 * @return array<string,mixed>
 */
function normalize_config(?array $input): array
{
    $input = $input ?? [];
    $doc = $input['doc'] ?? [];
    $keys = $input['keys'] ?? [];
    $ikey = (is_array($keys) ? ($keys['instance'] ?? null) : null) ?? 'instance';
    $dkey = (is_array($keys) ? ($keys['default'] ?? null) : null) ?? 'default';
    $reserved = $input['reserved'] ?? [];
    $profile = $input['profile'] ?? null;

    // The rename is applied at TWO PLACES AND NO OTHERS: the document
    // root, and every profile.<name> overlay root (§9.1). A rename applied
    // only at the root would leave `profile.prod.sdk` untranslated and
    // silently drop every environment override the host depends on.
    // Recursing further would be worse: option data is the definition's.
    $baseinst = $doc[$ikey] ?? null;
    $basedef = $doc[$dkey] ?? [];

    $overlay = null;
    if (null !== $profile) {
        $overlay = ($doc['profile'] ?? [])[$profile] ?? null;
    }
    if (!is_array($overlay)) {
        $overlay = [];
    }
    $overinst = $overlay[$ikey] ?? null;
    $overdef = $overlay[$dkey] ?? [];

    // Entry layers, base then overlay, each as {ref -> entry} plus the
    // order the form implies.
    $base = config_entries($baseinst);
    $over = config_entries($overinst);

    foreach ([array_keys($base['map']), array_keys($over['map']),
              array_keys($basedef), array_keys($overdef)] as $group) {
        foreach ($group as $r) {
            config_checkreserved((string)$r, $reserved);
        }
    }

    // A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the hard
    // way: deriving order from a partial array silently dropped
    // config-activated features. Refs in the base but absent from the
    // overlay still load, in sorted position AFTER the listed ones. A
    // profile may also INTRODUCE a ref the base never declared.
    $order = [];
    foreach ($over['order'] as $r) {
        if (!in_array($r, $order, true)) {
            $order[] = $r;
        }
    }
    // The remainder keeps the BASE's own order - array position for the
    // array form, sorted refs for the map form.
    foreach ($base['order'] as $r) {
        if (!in_array($r, $order, true)) {
            $order[] = $r;
        }
    }

    $instance = [];
    foreach ($order as $i => $ref) {
        $b = $base['map'][$ref] ?? null;
        $o = $over['map'][$ref] ?? null;

        // MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
        // (§9.3). A safety rule, not a tidiness one: if the overlay had
        // its defaults filled in before merging it would carry a
        // synthesized active:true and overwrite a base's false - silently
        // re-enabling a deliberately disabled integration in production.
        $active = config_pick($o, 'active', config_pick($b, 'active', true));
        $start = config_pick($o, 'start', config_pick($b, 'start', 'eager'));
        $block = config_pick($o, 'order', config_pick($b, 'order', null));

        // Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
        $layers = [];
        $nm = refname($ref);
        foreach ([$basedef[$nm] ?? null, $b, $overdef[$nm] ?? null, $o] as $src) {
            if (is_array($src) && array_key_exists('options', $src)) {
                $layers[] = $src['options'];
            }
        }

        $ent = ['pos' => $i, 'active' => $active, 'start' => $start,
                'optionlayers' => $layers];
        if (null !== $block) {
            $ent['order'] = $block;
        }
        $instance[$ref] = $ent;
    }

    // `default` DECLARES NOTHING (§9.3). It is a base for every instance
    // of that definition; it does not create one, and an entry for a name
    // with no instances is inert rather than an error - which is what
    // makes a shared library of defaults shippable.
    $defout = [];
    foreach ($basedef as $n => $v) {
        $defout[$n] = $v;
    }
    foreach ($overdef as $n => $v) {
        $defout[$n] = $v;
    }

    return ['instance' => $instance, 'order' => $order, 'default' => $defout];
}

/**
 * Both document forms reduce to {ref -> entry} plus the order the form
 * implies: array POSITION for the array form, sorted refs for the map
 * form.
 *
 * @param mixed $src
 * @return array{map:array<string,mixed>,order:string[]}
 */
function config_entries($src): array
{
    $out = ['map' => [], 'order' => []];
    if (null === $src) {
        return $out;
    }

    if (is_array($src) && array_is_list($src)) {
        foreach ($src as $item) {
            $ref = canon_ref($item['ref'] ?? null);
            $out['map'][$ref] = $item;
            $out['order'][] = $ref;
        }
        return $out;
    }

    // Map-form refs arrive as KEYS, through a different path than an array
    // element's `ref` field - and must canonicalize the same way.
    foreach ($src as $key => $value) {
        $out['map'][canon_ref((string)$key)] = $value;
    }
    // Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
    // sort identically under all three, so only mixed input discriminates:
    // '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. PHP's default
    // `sort` is NEITHER - it reads numeric-looking strings as numbers - so
    // this goes through Util::sortstrings and its SORT_STRING flag.
    $out['order'] = Util::sortedkeys($out['map']);
    return $out;
}

/**
 * §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
 * too. A configuration surface that can disable the thing reading it is
 * not a surface, it is a trap.
 *
 * @param string[] $reserved
 */
function config_checkreserved(string $ref, array $reserved): void
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
 * PRESENCE decides, not truthiness and not null. A JSON `null` is a
 * present value in JavaScript (`undefined !== null`), so it must be one
 * here - and in PHP `isset()` reads a present null as absent, which is why
 * this asks `array_key_exists`.
 *
 * @param mixed $src
 * @param mixed $dflt
 * @return mixed
 */
function config_pick($src, string $key, $dflt)
{
    return is_array($src) && array_key_exists($key, $src) ? $src[$key] : $dflt;
}

// ---------------------------------------------------------------------
// resolve_options - §9.3's ten levels, and 9.4's directives
// ---------------------------------------------------------------------

/**
 * @param array<string,mixed> $input
 * @return array<string,mixed>
 */
function resolve_options(array $input): array
{
    $shape = $input['shape'] ?? [];
    if (!is_array($shape)) {
        $shape = [];
    }
    check_shape($shape);

    $ref = canon_ref($input['ref'] ?? null);
    $name = refname($ref);
    $doc = $input['doc'] ?? [];
    $profile = $input['profile'] ?? null;

    $overlay = null;
    if (null !== $profile) {
        $overlay = ($doc['profile'] ?? [])[$profile] ?? null;
    }
    if (!is_array($overlay)) {
        $overlay = [];
    }

    // ONE ordered merge, lowest to highest. Levels 3-6 are not two
    // namespaces collapsed separately and composed afterwards: that
    // inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
    // SPECIFICITY, so a prod per-definition default would lose to a base
    // instance value.
    $layers = [
        config_defaultsof($shape),                             // 1
        $input['hostdefaults'] ?? null,                        // 2
        config_optsof($doc['default'] ?? null, $name),         // 3
        config_optsof($doc['instance'] ?? null, $ref),         // 4
        config_optsof($overlay['default'] ?? null, $name),     // 5
        config_optsof($overlay['instance'] ?? null, $ref),     // 6
        $input['env'] ?? null,                                 // 7
        $input['hostoptions'] ?? null,                         // 8
        $input['loadoptions'] ?? null,                         // 9
        $input['patch'] ?? null,                               // 10
    ];

    $out = [];
    foreach ($layers as $layer) {
        if (null === $layer) {
            continue;
        }
        $out = config_mergeone($out, $layer, $shape);
    }
    return $out;
}

/**
 * The shape's non-directive values are the level-1 defaults.
 *
 * @param array<string,mixed> $shape
 * @return array<string,mixed>
 */
function config_defaultsof(array $shape): array
{
    $out = [];
    foreach ($shape as $k => $v) {
        if (is_array($v) && array_key_exists('$MERGE', $v)) {
            continue;
        }
        $out[$k] = $v;
    }
    return $out;
}

/**
 * @param mixed $src
 * @return mixed
 */
function config_optsof($src, string $key)
{
    if (null === $src) {
        return null;
    }

    // The array form is equivalent to the map form (§9.1).
    if (is_array($src) && array_is_list($src)) {
        foreach ($src as $item) {
            if (canon_ref($item['ref'] ?? null) === $key) {
                return $item['options'] ?? null;
            }
        }
        return null;
    }

    foreach ($src as $k => $entry) {
        if (canon_ref((string)$k) !== $key) {
            continue;
        }
        return is_array($entry) ? ($entry['options'] ?? null) : null;
    }
    return null;
}

/**
 * Merge ONE layer onto the accumulator, honouring the shape's directives.
 * The directive holds at EVERY precedence level, not only between document
 * levels - §9.4 makes it a property of the shape, which does not know
 * which layer a value arrived from.
 *
 * @param mixed $base
 * @param mixed $over
 * @param array<string,mixed>|null $shape
 * @return mixed
 */
function config_mergeone($base, $over, ?array $shape)
{
    if (null === $over) {
        return $base;
    }
    if (!is_array($base) || !is_array($over)) {
        return Util::clone_value($over);
    }

    $out = $base;

    foreach ($over as $k => $o) {
        $directive = null;
        if (is_array($shape) && is_array($shape[$k] ?? null)) {
            $directive = $shape[$k]['$MERGE'] ?? null;
        }
        $b = $out[$k] ?? null;

        if ('replace' === $directive) {
            $out[$k] = Util::clone_value($o);
        } elseif ('append' === $directive) {
            $bl = is_array($b) ? $b : [];
            $ol = is_array($o) ? $o : [$o];
            $out[$k] = array_merge(array_values($bl), array_values($ol));
        } elseif (is_array($directive) && array_key_exists('deep', $directive)) {
            $out[$k] = config_deepto($b, $o, $directive['deep']);
        } else {
            // Library default: deep for maps, REPLACE for lists.
            // struct.merge is element-wise by index, which for option maps
            // is nearly always wrong - ["a"] over ["x","y","z"] yielding
            // ["a","y","z"] is the defect station hit on
            // secrets.providers.
            //
            // PHP HAS ONE ARRAY TYPE, so "both are maps" is
            // `Util::maplike` - anything but a non-empty list - and
            // Types.php says why the empty case reads as a map.
            if (Util::maplike($b) && Util::maplike($o)) {
                $out[$k] = config_mergeone($b, $o, null);
            } else {
                $out[$k] = Util::clone_value($o);
            }
        }
    }
    return $out;
}

/**
 * Merge N levels below this key, replace below that.
 *
 * @param mixed $base
 * @param mixed $over
 * @param mixed $n
 * @return mixed
 */
function config_deepto($base, $over, $n)
{
    if ($n <= 0) {
        return Util::clone_value($over);
    }
    if (!Util::maplike($base) || !Util::maplike($over)) {
        return Util::clone_value($over);
    }

    $out = $base;
    foreach ($over as $k => $v) {
        $out[$k] = config_deepto($out[$k] ?? null, $v, $n - 1);
    }
    return $out;
}

/**
 * §9.4: N is an integer of at least 1, and everything else is an error.
 *
 * `{"deep": 0}` is rejected DESPITE having an obvious reading, because
 * "replace at this key" already has a spelling and two spellings for one
 * behaviour is the defect class this repo exists to avoid.
 *
 * @param mixed $shape
 */
function check_shape($shape): void
{
    if (!is_array($shape)) {
        return;
    }

    foreach ($shape as $k => $v) {
        if (!is_array($v) || !array_key_exists('$MERGE', $v)) {
            continue;
        }

        $directive = $v['$MERGE'];

        if (is_string($directive)) {
            if (in_array($directive, MERGE_WORDS, true)) {
                continue;
            }
            fail_with('plugin_shape_invalid',
                      'invalid $MERGE directive at ' . $k . ': ' . $directive,
                      ['key' => $k, 'directive' => $directive]);
        }

        if (is_array($directive) && array_key_exists('deep', $directive)) {
            $n = $directive['deep'];
            // `is_int` excludes `true`, which PHP would otherwise read as
            // 1 in a numeric comparison - the same hole python has to
            // guard and ruby does not.
            if (is_int($n) && $n >= 1) {
                continue;
            }

            fail_with('plugin_shape_invalid',
                      'invalid $MERGE deep at ' . $k . ': ' . Util::json($n),
                      ['key' => $k, 'directive' => $directive]);
        }

        fail_with('plugin_shape_invalid',
                  'invalid $MERGE directive at ' . $k . ': ' . Util::json($directive),
                  ['key' => $k, 'directive' => $directive]);
    }
}
