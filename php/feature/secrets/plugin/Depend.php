<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Depend.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Dependency cardinality, policy, and the restart graph (§11.3).
 *
 * TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
 * because only it knows what it can cope with:
 *
 *                | static (default)          | dynamic
 *   -------------|---------------------------|--------------------------
 *   mandatory    | unmet -> pending;         | unmet -> pending;
 *   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
 *                |          recursively      |          notified
 *   -------------|---------------------------|--------------------------
 *   optional:true| never gates activation;   | never gates activation;
 *                | a change deactivates and  | a change is a
 *                | reactivates               | notification, nothing else
 *
 * `dynamic` means the plugin has said, IN WRITING, that it can survive its
 * provider being swapped underneath it. It is not the default because most
 * plugins cannot, and the cost of wrongly assuming they can is a live
 * instance holding a dead reference.
 *
 * The rebinding-preference axis is deliberately omitted. OSGi has
 * reluctant vs greedy and it is a knob every author must understand to
 * read anyone else's component; we take always-reluctant. Three axes were
 * more than the model can carry across twenty ports.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

/**
 * A bare string is shorthand for `{name}`.
 *
 * @param mixed $raw
 * @return array<string,mixed>
 */
function normrequire($raw): array
{
    if (is_string($raw)) {
        return ['name' => $raw];
    }
    return is_array($raw) ? $raw : [];
}

/**
 * The requirements a definition declared, normalized.
 *
 * BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
 *
 * The instance-level `policy` and `optional` list are how a DOCUMENT
 * states the axis without editing the definition, and they apply to every
 * requirement. The per-requirement form is the one §11.1's object syntax
 * exists for, and it is strictly more expressive: an instance that is
 * `static` on its store and `dynamic` on its metrics cannot be written at
 * all at the instance level.
 *
 * `optional` unions rather than overriding - both spellings are statements
 * that this requirement need not gate activation, and there is no reading
 * under which one of them means "actually, mandatory".
 *
 * @param array<string,mixed>|null $options
 * @return array<int,array<string,mixed>>
 */
function requirements(?array $options): array
{
    $options = $options ?? [];
    $raw = $options['requires'] ?? [];
    $marked = $options['optional'] ?? [];
    $fallback = $options['policy'] ?? null;

    $out = [];
    foreach ($raw as $item) {
        $req = normrequire($item);
        if (Util::truthy($req['optional'] ?? null)
            || (is_array($marked) && in_array($req['name'] ?? null, $marked, true))) {
            $req['optional'] = true;
        }
        if (null === ($req['policy'] ?? null) && null !== $fallback) {
            $req['policy'] = $fallback;
        }
        $out[] = $req;
    }
    return $out;
}

/**
 * Does losing this requirement's SELECTED provider restart the consumer?
 * The mandatory ones under `static`, and the `static` optional ones - both
 * make a capability change deactivate and reactivate. `dynamic` never
 * restarts.
 *
 * @param array<string,mixed> $req
 */
function restartsonloss(array $req): bool
{
    return 'dynamic' !== ($req['policy'] ?? 'static');
}

/**
 * Does an unmet requirement keep the consumer out of `live`?
 *
 * Cardinality alone decides this, NOT policy. `dynamic` is a statement
 * about surviving a SWAP, not about starting without the thing at all - a
 * mandatory-dynamic consumer still waits in `pending` for its first
 * provider.
 *
 * @param array<string,mixed> $req
 */
function gatesactivation(array $req): bool
{
    return true !== ($req['optional'] ?? null);
}

/**
 * Edges that can cause a restart, which is exactly the set a cycle must be
 * detected over (§11.3).
 *
 * ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
 * exclusion was for: two plugins that optionally and dynamically consume
 * each other's capabilities both activate happily, neither gates on the
 * other, and each is merely notified when the other appears. Nothing
 * restarts, so nothing oscillates.
 *
 * An earlier draft of §11.3 excluded EVERY optional edge and thereby
 * admitted the non-terminating case it was trying to permit.
 *
 * @param array<string,mixed> $req
 */
function restartcausing(array $req): bool
{
    return gatesactivation($req) || restartsonloss($req);
}

/**
 * A cycle through restart-causing requirements is
 * `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
 * because the failure it describes is a non-terminating reconcile and the
 * only safe time to report that is before it starts.
 *
 * The graph is over capabilities, not refs: an edge runs from a consumer
 * to EVERY node that provides what it needs, because any of them could be
 * the one selected and a cycle through any is a cycle. A node also
 * satisfies its own name as a ref (§11.1), which is why the ref is a
 * provider of itself here.
 *
 * @param array<int,array<string,mixed>> $nodes
 * @return string[]|null
 */
function dependencycycle(array $nodes): ?array
{
    // TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    // matched differently — a capability by its exact name, a ref through
    // the canonical spelling (§4 rule 5) — and one map keyed by both can
    // only do one of them. Keyed by both and looked up raw, as this was,
    // a cycle spelled `a$`/`b$` found no providers and EVADED the
    // load-time check that exists to catch a non-terminating reconcile.
    $bycap = [];
    $isref = [];
    foreach ($nodes as $n) {
        $isref[$n['ref']] = true;
        foreach ($n['provides'] as $cap) {
            if (!array_key_exists($cap, $bycap)) {
                $bycap[$cap] = [];
            }
            $bycap[$cap][] = $n['ref'];
        }
    }

    $edges = [];
    foreach ($nodes as $n) {
        $out = [];
        foreach ($n['requires'] as $req) {
            if (!restartcausing($req)) {
                continue;
            }
            $from = $bycap[$req['name']] ?? [];
            // A node satisfies its own name AS A REF (§11.1),
            // canonically — exactly what `providersof` does at runtime.
            // `canon` hands back a name no ref could have unchanged, and
            // no instance ref can equal one, so it is the tolerant test.
            $asref = canon($req['name']);
            if (($isref[$asref] ?? false) && !in_array($asref, $from, true)) {
                $from[] = $asref;
            }
            foreach ($from as $p) {
                if ($p !== $n['ref'] && !in_array($p, $out, true)) {
                    $out[] = $p;
                }
            }
        }
        $edges[$n['ref']] = Util::sortstrings($out);
    }

    // Iterative DFS with an explicit stack: twenty ports, and several of
    // them have no recursion budget worth relying on.
    $white = 0;
    $grey = 1;
    $black = 2;
    $colour = [];
    foreach ($nodes as $n) {
        $colour[$n['ref']] = $white;
    }

    foreach (Util::sortedkeys($edges) as $start) {
        if ($colour[$start] !== $white) {
            continue;
        }

        $path = [$start];
        $stack = [[$start, 0]];
        $colour[$start] = $grey;

        while (!empty($stack)) {
            $top = &$stack[count($stack) - 1];
            if ($top[1] >= count($edges[$top[0]])) {
                $colour[$top[0]] = $black;
                unset($top);
                array_pop($stack);
                array_pop($path);
                continue;
            }
            $nxt = $edges[$top[0]][$top[1]];
            $top[1]++;
            unset($top);
            if ($colour[$nxt] === $grey) {
                // Report the cycle itself, not the walk that found it.
                $at = array_search($nxt, $path, true);
                return array_merge(array_slice($path, (int)$at), [$nxt]);
            }
            if ($colour[$nxt] === $black) {
                continue;
            }
            $colour[$nxt] = $grey;
            $path[] = $nxt;
            $stack[] = [$nxt, 0];
        }
    }
    return null;
}

/**
 * Raise on a cycle, naming it. Separate from the detector so the detector
 * stays pure and corpus-testable.
 *
 * @param array<int,array<string,mixed>> $nodes
 */
function checkcycle(array $nodes): void
{
    $cycle = dependencycycle($nodes);
    if (null === $cycle) {
        return;
    }
    fail_with('plugin_dependency_cycle',
              'requirements cycle: ' . implode(' -> ', $cycle),
              ['cycle' => $cycle]);
}
