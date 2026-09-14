<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Graph.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Whole-graph resolution (§11.4) - a phase, not a discovery.
 *
 * "Activate, and wait in `pending` if you must" is correct and, on its
 * own, produces a terrible experience: apply twenty instances against a
 * registry missing one thing and you get NINETEEN pending rows and no
 * statement of what is actually wrong.
 *
 * `resolve_graph` is a PURE FUNCTION of the registry and the intended
 * activation set. No callbacks run, no state changes, nothing is touched.
 * It answers for the whole graph at once which instances can be live, and
 * for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
 *
 * The failure mode being designed against is a famous one: OSGi's resolver
 * is correct and its diagnostics are legendarily unusable. A resolver that
 * says "blocked" without saying WHY has moved the problem rather than
 * solved it, so `why` is part of the contract and the corpus pins its
 * shape.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

/**
 * @param array<int,array<string,mixed>> $nodes
 * @return array{resolved:string[],blocked:array<int,mixed>}
 */
function resolve_graph(array $nodes): array
{
    $byref = [];
    foreach ($nodes as $n) {
        $byref[$n['ref']] = $n;
    }

    $resolved = [];
    $blocked = [];

    // Fixed point: a node resolves when every mandatory requirement is met
    // by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
    // makes a provider that is itself blocked propagate, rather than each
    // node being judged against the raw registry.
    $moved = true;
    while ($moved) {
        $moved = false;
        foreach ($nodes as $n) {
            if ($resolved[$n['ref']] ?? false) {
                continue;
            }
            if (null !== firstunmet($n, $byref, $resolved)) {
                continue;
            }
            $resolved[$n['ref']] = true;
            $moved = true;
        }
    }

    foreach ($nodes as $n) {
        if ($resolved[$n['ref']] ?? false) {
            continue;
        }
        $why = firstunmet($n, $byref, $resolved);
        if (null !== $why) {
            $blocked[$n['ref']] = $why;
        }
    }

    $out = [];
    foreach (Util::sortedkeys($blocked) as $r) {
        $out[] = $blocked[$r];
    }
    return ['resolved' => Util::sortedkeys($resolved), 'blocked' => $out];
}

/**
 * The FIRST unmet requirement, with the most specific explanation
 * available. Order matters: "no provider at all" and "a provider at the
 * wrong version" are different problems and a reader must not have to
 * guess which they have.
 *
 * @param array<string,mixed> $node
 * @param array<string,array<string,mixed>> $byref
 * @param array<string,bool> $resolved
 * @return array<string,mixed>|null
 */
function firstunmet(array $node, array $byref, array $resolved): ?array
{
    foreach ($node['requires'] ?? [] as $req) {
        if (Util::truthy($req['optional'] ?? null)) {
            continue;
        }

        $all = graph_candidates($byref, $req['name']);
        if (empty($all)) {
            return ['ref' => $node['ref'], 'unmet' => $req['name'],
                    'why' => ['kind' => 'absent']];
        }

        $ok = resolve_capability($req, $all);
        if (!empty($ok)) {
            // A provider exists and matches - but if none of them is
            // itself resolved, this node is blocked BEHIND it, and the
            // chain is the useful answer rather than "unmet".
            $any = false;
            foreach ($ok as $c) {
                if ($resolved[$c['ref']] ?? false) {
                    $any = true;
                    break;
                }
            }
            if ($any) {
                continue;
            }
            $chain = Util::sortstrings(array_map(static function ($c) {
                return $c['ref'];
            }, $ok));
            return ['ref' => $node['ref'], 'unmet' => $req['name'],
                    'why' => ['kind' => 'blocked', 'chain' => $chain]];
        }

        // Providers exist and none matched. Say which test failed.
        if (null !== ($req['range'] ?? null)) {
            $versions = [];
            foreach ($all as $c) {
                $have = $c['provides']['version'] ?? null;
                if (null === $have || !satisfiesq($have, $req['range'])) {
                    $versions[] = $have ?? '(none)';
                }
            }
            if (!empty($versions)) {
                return ['ref' => $node['ref'], 'unmet' => $req['name'],
                        'why' => ['kind' => 'version', 'range' => $req['range'],
                                  'found' => Util::sortstrings($versions)]];
            }
        }

        if (null !== ($req['match'] ?? null)) {
            foreach ($all as $c) {
                $attrs = $c['provides']['attrs'] ?? [];
                foreach (Util::sortedkeys($req['match']) as $k) {
                    if (array_key_exists($k, $attrs)
                        && matchvalue($req['match'][$k], $attrs[$k])) {
                        continue;
                    }
                    return ['ref' => $node['ref'], 'unmet' => $req['name'],
                            'why' => ['kind' => 'match', 'failing' => $k,
                                      'want' => $req['match'][$k],
                                      'found' => $attrs[$k] ?? null]];
                }
            }
        }

        return ['ref' => $node['ref'], 'unmet' => $req['name'],
                'why' => ['kind' => 'absent']];
    }
    return null;
}

/**
 * @param array<string,array<string,mixed>> $byref
 * @return array<int,array<string,mixed>>
 */
function graph_candidates(array $byref, string $name): array
{
    $out = [];
    // A NODE SATISFIES ITS OWN REF (§11.1), and the graph learned it
    // here. Considering only declared capabilities made `resolve` answer
    // `absent` about a provider sitting right there and live — §11.4's
    // job is explaining the graph the runtime reconciles, and it was
    // explaining a different one.
    $asref = canon($name);
    foreach (Util::sortedkeys($byref) as $ref) {
        $node = $byref[$ref];
        // The ref match WINS OUTRIGHT for that node, as at runtime: one
        // candidate, not two, for a node both named `b` and providing `b`.
        if ($ref === $asref) {
            $out[] = ['ref' => $node['ref'], 'pos' => $node['pos'] ?? 0,
                      'provides' => ['name' => $name]];
            continue;
        }
        foreach ($node['provides'] ?? [] as $prov) {
            if (($prov['name'] ?? null) !== $name) {
                continue;
            }
            $out[] = ['ref' => $node['ref'], 'pos' => $node['pos'] ?? 0,
                      'provides' => $prov];
        }
    }
    return $out;
}
