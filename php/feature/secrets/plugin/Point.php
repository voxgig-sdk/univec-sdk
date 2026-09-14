<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Point.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Extension points (§6). Three kinds, chosen because they are what the two
 * existing systems actually needed, and no more.
 *
 * A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
 * deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
 * undoable, but "this instance holds slot 3 of the request chain" is
 * undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
 * paper called *Listeners Considered Harmful*, and for exactly this
 * reason.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

/**
 * §6.1: "fan-out" is not one answer but four. In a language with
 * asynchrony, "call every binding" hides a decision - start them all and
 * wait, await each in turn, or do not wait - and a design that leaves it
 * unsaid gets four different answers from four ports, in the concurrency
 * behaviour of production code no corpus entry happens to cover.
 */
const MODES = ['emit', 'parallel', 'serial', 'bail'];

/**
 * Fan-out. Return values are ignored except in `bail`.
 *
 * @param array<int,array<string,mixed>> $bindings
 * @param mixed $arg
 * @return mixed
 */
function point_emit(array $bindings, string $mode, $arg)
{
    if ('bail' === $mode) {
        // Stops at the first binding that RETURNS A VALUE - the "handled,
        // stop" case. A `null` RETURN DECLINES (§6.1): php has one way to
        // say nothing, and the model's rule is written to that rather than
        // to JavaScript's null/undefined pair. `null !== $v`, NOT
        // `if ($v)` - `false`, `0` and `''` are values.
        foreach ($bindings as $b) {
            $v = ($b['fn'])($arg);
            if (null !== $v) {
                return $v;
            }
        }
        return null;
    }

    $errors = [];
    foreach ($bindings as $b) {
        try {
            ($b['fn'])($arg);
        } catch (\Throwable $e) {
            // `emit` raises synchronously; the collecting modes gather.
            if ('emit' === $mode) {
                throw $e;
            }
            $errors[] = $e;
        }
    }
    return 'emit' === $mode ? null : $errors;
}

/**
 * Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (§6.2).
 *
 * Recomputed by the host whenever the live set changes, and cached between
 * changes. Plugins receive `next` as an argument; they never see or store
 * the previous value of anything. A plugin that stashes `next` and calls
 * it after deactivation is a bug the host cannot prevent, and this says so
 * rather than pretending otherwise.
 *
 * @param array<int,array<string,mixed>> $bindings
 */
function compose(array $bindings, callable $base): callable
{
    $nxt = $base;
    for ($i = count($bindings) - 1; $i >= 0; $i--) {
        $fn = $bindings[$i]['fn'];
        $inner = $nxt;
        // `use` captures BY VALUE at creation, so each layer closes over
        // its own pair without the block-local dance ruby needs.
        $nxt = static function (...$args) use ($fn, $inner) {
            return $fn($inner, ...$args);
        };
    }
    return $nxt;
}

/**
 * At most one live implementation (§6.3). The winner is the highest band,
 * ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than silently
 * ignored.
 *
 * @param array<int,array<string,mixed>> $bindings
 * @param array<string,mixed> $spec
 * @return array{winner:array<string,mixed>|null,shadowed:string[]}
 */
function point_provider(array $bindings, array $spec): array
{
    if (empty($bindings)) {
        return ['winner' => null, 'shadowed' => []];
    }

    if (Util::truthy($spec['exclusive'] ?? null) && count($bindings) > 1) {
        $refs = Util::sortstrings(array_map(static function ($b) {
            return $b['ref'];
        }, $bindings));
        fail_with('plugin_point_exclusive',
                  'point is exclusive and has ' . count($bindings)
                  . ' bindings: ' . implode(', ', $refs),
                  ['refs' => $refs]);
    }

    $ranked = Util::stable_sort_by($bindings, static function ($b) {
        return [-$b['band'], $b['ref']];
    });
    $shadowed = [];
    foreach (array_slice($ranked, 1) as $b) {
        $shadowed[] = $b['ref'];
    }
    return ['winner' => $ranked[0], 'shadowed' => $shadowed];
}
