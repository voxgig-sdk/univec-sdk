<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Order.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Ordering (§7) - one rule, one place.
 *
 * sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
 * and the third was not far off. This sort is the whole replacement, and
 * the tiers are in this order for a reason:
 *
 *   1 constraints   before/after edges, by ref or by name
 *   2 bands         integer, lower first, default 0
 *   3 declaration   ties break by `pos`
 *
 * CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
 * present. A band expresses a genuine cross-cutting layer; a constraint
 * expresses a relationship between two specific things; and a band chosen
 * by trial and error to fix an ordering bug is a bug wearing a number.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

/**
 * @param array<int,array<string,mixed>> $bindings
 * @param array<string,string>|null $pin
 * @return string[]
 */
function resolve_order(array $bindings, ?array $pin = null): array
{
    $nodes = array_values($bindings);
    $byref = [];
    foreach ($nodes as $b) {
        $byref[$b['ref']] = $b;
    }

    // Constraints are edges. A constraint naming an ABSENT binding is
    // satisfied VACUOUSLY (§7) - a plugin ordered `after: 'test'` must
    // load in a host with no test plugin. That is sdkgen's __after__
    // behaviour, kept.
    $edges = [];
    foreach ($nodes as $b) {
        $edges[$b['ref']] = [];
    }

    foreach ($nodes as $b) {
        $block = $b['order'] ?? [];
        if (!is_array($block)) {
            $block = [];
        }
        // An ABSENT constraint and an EMPTY LIST are both "no constraint".
        if (order_declared($block['after'] ?? null)) {
            foreach (order_targets($block['after'], $nodes) as $t) {
                $edges[$t][] = $b['ref'];
            }
        }
        if (order_declared($block['before'] ?? null)) {
            foreach (order_targets($block['before'], $nodes) as $t) {
                $edges[$b['ref']][] = $t;
            }
        }
    }

    // Stable topological sort. Among ready nodes, band first (lower runs
    // first), then `pos` - the position the DOCUMENT visibly states, not
    // the order instances happened to load and not the incarnation `seq`.
    $indeg = [];
    foreach ($nodes as $b) {
        $indeg[$b['ref']] = 0;
    }
    foreach ($edges as $tos) {
        foreach ($tos as $to) {
            $indeg[$to]++;
        }
    }

    $out = [];
    $ready = [];
    foreach ($nodes as $b) {
        if (0 === $indeg[$b['ref']]) {
            $ready[] = $b;
        }
    }

    while (!empty($ready)) {
        $ready = Util::stable_sort_by($ready, static function ($b) {
            return [order_band($b), $b['pos'] ?? 0];
        });
        $nxt = array_shift($ready);
        $out[] = $nxt['ref'];
        foreach ($edges[$nxt['ref']] as $to) {
            $indeg[$to]--;
            if (0 === $indeg[$to]) {
                $ready[] = $byref[$to];
            }
        }
    }

    if (count($out) !== count($nodes)) {
        $stuck = [];
        foreach ($nodes as $b) {
            if (!in_array($b['ref'], $out, true)) {
                $stuck[] = $b['ref'];
            }
        }
        fail_with('plugin_order_cycle',
                  'before/after constraints cycle: ' . implode(' -> ', $stuck),
                  ['cycle' => $stuck]);
    }

    return applypin($out, $edges, $pin);
}

/**
 * @param array<string,mixed> $binding
 */
function order_band(array $binding): int
{
    $block = $binding['order'] ?? [];
    $value = is_array($block) ? ($block['band'] ?? null) : null;
    // `is_int` and not `is_numeric`: §7's band is an integer, and PHP
    // reads `true` as neither an int nor a float, so the boolean case
    // falls out here the way it does in ruby.
    return is_int($value) ? $value : 0;
}

/**
 * Was a constraint stated? An absent value and an EMPTY LIST are both
 * no-constraint - and `[]` is FALSY in php, which is the mirror image of
 * the ruby trap: a plain truthiness test gets the empty list right here
 * and the empty STRING wrong, so this tests the spelling either way.
 *
 * @param mixed $spec
 */
function order_declared($spec): bool
{
    if (null === $spec) {
        return false;
    }
    if (is_array($spec)) {
        foreach ($spec as $one) {
            if ('' !== $one) {
                return true;
            }
        }
        return false;
    }
    return '' !== $spec;
}

/**
 * One spelling or a LIST of them. A list fans out to the UNION of what
 * each names, so after: ['a','b'] means after BOTH, and the same instance
 * named twice - once by name, once by ref - is one edge.
 *
 * @param mixed $spec
 * @param array<int,array<string,mixed>> $nodes
 * @return string[]
 */
function order_targets($spec, array $nodes): array
{
    $specs = is_array($spec) ? $spec : [$spec];
    $hit = [];
    foreach ($specs as $one) {
        foreach ($nodes as $b) {
            if (in_array($b['ref'], $hit, true)) {
                continue;
            }
            if ($b['ref'] === $one || refname($b['ref']) === $one) {
                $hit[] = $b['ref'];
            }
        }
    }
    return $hit;
}

/**
 * A PIN IS NOT A CONSTRAINT (§7).
 *
 * Constraints and bands are negotiable by definition - they are what
 * plugins and documents say they want, and the sort's job is to satisfy
 * them all. A pin is the host stating a structural invariant of its own
 * architecture, which is a different kind of claim and must not lose a tie
 * to a document.
 *
 * So a pin PLACES the binding at the named end, and an ordering that would
 * move it away is `plugin_order_pinned` - rejected, not honoured into a
 * broken wrap.
 *
 * @param string[] $order
 * @param array<string,string[]> $edges
 * @param array<string,string>|null $pin
 * @return string[]
 */
function applypin(array $order, array $edges, ?array $pin): array
{
    if (null === $pin) {
        return $order;
    }

    $out = $order;

    // SORTED, not insertion order. A pin map is data - it can arrive from
    // a host's own construction options in any order, and two names pinned
    // to the same end are order-sensitive (`{b:'first', a:'first'}` and
    // `{a:'first', b:'first'}` give different results). PHP arrays keep
    // insertion order and a Go map has none at all, so leaving it unstated
    // made the same declaration mean different things in different ports.
    foreach (Util::sortedkeys($pin) as $name) {
        $want = $pin[$name];
        $idx = null;
        foreach ($out as $i => $r) {
            if (refname($r) === $name) {
                $idx = $i;
                break;
            }
        }
        if (null === $idx) {
            continue;
        }

        // `first`/`outermost` is index 0; `last`/`innermost` is the end.
        // §6.2 makes the first chain binding outermost, which is why the
        // vocabulary is positional and why the two spellings pair this
        // way.
        $wantfirst = in_array($want, ['first', 'outermost'], true);
        $ref = $out[$idx];
        array_splice($out, $idx, 1);
        if ($wantfirst) {
            array_unshift($out, $ref);
        } else {
            $out[] = $ref;
        }
    }

    // Now check that the placement did not break a constraint. This is the
    // half that makes a pin a rejection rather than an override: the host
    // wins on position, but it does not get to silently discard a
    // relationship a plugin declared.
    $at = [];
    foreach ($out as $i => $r) {
        $at[$r] = $i;
    }
    foreach ($edges as $from => $tos) {
        foreach ($tos as $to) {
            if ($at[$from] <= $at[$to]) {
                continue;
            }
            fail_with('plugin_order_pinned',
                      'a pin would move a binding an ordering constrains: '
                      . $from . ' must precede ' . $to,
                      ['before' => $from, 'after' => $to]);
        }
    }

    return $out;
}
