<?php
// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (php/src/Host.php)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * The host: the lifecycle state machine (§5), extension points (§6), and
 * resource capture (§8).
 *
 * TWO RULES SHAPE EVERY METHOD BELOW.
 *
 * Transitions are SEQUENTIAL (§5.2). One at a time, in call order, never
 * interleaved; a transition triggered from inside a lifecycle callback is
 * `plugin_reentrant`. A hard rule, because it is the only way the
 * semantics can be identical in Go, in PHP and in single-threaded
 * JavaScript.
 *
 * Reconciliation is EAGER (§18's portability budget). A transition settles
 * by running the state machine to a fixed point, not by suspending on a
 * promise.
 *
 * AND ONE RULE SHAPES THE SHAPE. A PHP array is a VALUE: reading an
 * instance record out of the registry copies it, and writing to the copy
 * changes nothing. Every record the host mutates is therefore an `Entry`
 * OBJECT, and `Inst` holds that object rather than an array.
 */

declare(strict_types=1);

namespace Voxgig\Plugin;

/**
 * One instance's record. An object, not an array, so that the registry,
 * the `Inst` handed to callbacks and any closure that captured it all see
 * one set of values (see the file header).
 */
class Entry
{
    public string $ref;

    /** @var array<string,mixed> */
    public array $def;

    public string $status = 'declared';

    public int $pos = 0;

    public int $seq = 0;

    /** @var array<string,mixed> */
    public array $options = [];

    /** The mutable per-instance state a definition owns (§5.4). */
    public Bag $state;

    /** @var mixed */
    public $order = null;

    /** @var string[] */
    public array $unmet = [];

    /** @var array<int,callable> */
    public array $scope = [];

    /**
     * §11.4's ALWAYS-RELUCTANT rebinding made concrete: the provider ref
     * this instance's activation actually chose, per requirement name.
     * Re-ranking on every question silently re-points a live consumer at
     * any better newcomer, and then losing the provider it was really
     * using does not restart it.
     *
     * @var array<string,string>
     */
    public array $selected = [];

    /** @var array<int,array<string,mixed>> */
    public array $bindings = [];

    /** @var array<string,mixed> */
    public array $exports = [];

    /** @var array<int,array<string,mixed>> */
    public array $provides = [];

    public ?Host $inner = null;

    public bool $barred = false;

    public function __construct(string $ref, array $def)
    {
        $this->ref = $ref;
        $this->def = $def;
        $this->state = new Bag();
    }
}

/**
 * What a definition's callbacks see. Deliberately not the internal record:
 * a plugin that could reach `status` could also write it.
 */
class Inst
{
    public string $ref;

    public string $name;

    public string $tag;

    /**
     * The instance's own mutable state. A `Bag` rather than an array so
     * that `$i->state['count'] = 1` and `$i->state['unwound'][] = 2` reach
     * the instance instead of a copy - PHP's arrays are values, and this
     * is the one place a plugin author would never expect that.
     */
    public Bag $state;

    private Host $hostref;

    private Entry $entry;

    public function __construct(Host $host, Entry $entry)
    {
        $this->hostref = $host;
        $this->entry = $entry;
        $this->ref = $entry->ref;
        $parsed = parse_ref($entry->ref);
        $this->name = $parsed['name'];
        $this->tag = $parsed['tag'];
        $this->state = $entry->state;
    }

    /**
     * The resolved options, READ FRESH. `apply` and `options` replace the
     * map wholesale, so a callback that cached this at `define` would hold
     * the values a later document already changed.
     *
     * @return array<string,mixed>
     */
    public function options(): array
    {
        return $this->entry->options;
    }

    public function host(): Host
    {
        return $this->hostref;
    }

    /**
     * Foreign resources the host did not hand out are registered
     * explicitly (§8.3); host calls are recorded automatically.
     *
     * SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
     * resources CURRENTLY HELD, so an entry that is registered and then
     * unwound must leave the count where it found it.
     */
    public function release(callable $fn): void
    {
        // §8.3: "`inst.release` outside `activate` is
        // `plugin_release_scope`". `intransition` is true in `define` too,
        // and a scope entry registered there is never unwound.
        if ('activate' !== $this->hostref->phase()) {
            fail_with('plugin_release_scope', 'release called outside activate');
        }
        $host = $this->hostref;
        $done = new \stdClass();
        $done->at = false;
        $this->entry->scope[] = static function () use ($done, $host, $fn) {
            if (!$done->at) {
                $done->at = true;
                $host->open_dec();
                $fn();
            }
        };
        $host->open_inc();
    }

    /**
     * The synthetic counter the driver owns, so "what is open" is data
     * rather than an assertion each port words differently.
     *
     * Returns its own release, so a plugin can hand one back early. The
     * scope still holds the entry and unwinding it twice is a no-op -
     * releasing early must not make teardown wrong.
     */
    public function acquire(): callable
    {
        // §8.1: resources are "acquired during `activate` - the scope's
        // actual job". Same reason as `release` above.
        if ('activate' !== $this->hostref->phase()) {
            fail_with('plugin_release_scope', 'acquire called outside activate');
        }
        $host = $this->hostref;
        $done = new \stdClass();
        $done->at = false;
        $rel = static function () use ($done, $host) {
            if (!$done->at) {
                $done->at = true;
                $host->open_dec();
            }
        };
        $this->entry->scope[] = $rel;
        $host->open_inc();
        return $rel;
    }

    /**
     * Bind into a host point. Declared in `define`; the host inserts it
     * only after `activate` returns successfully (§8.1), which is why a
     * failing activate leaves no live binding behind.
     */
    public function bind(string $point, callable $fn, $band = null): void
    {
        // §12 has carried `plugin_bind_scope` - "binding declared outside
        // `define`" - since before anything raised it. §8.1 puts binding
        // DECLARATION in `define` and INSERTION at a successful activate,
        // and the guard was the half nobody wrote: a binding added from
        // `activate` went live without being part of the loaded
        // definition, and a deactivate/activate cycle appended it again.
        if ('define' !== $this->hostref->phase()) {
            fail_with('plugin_bind_scope', 'bind called outside define: ' . $point,
                      ['ref' => $this->ref, 'point' => $point]);
        }
        if (!$this->hostref->haspoint($point)) {
            fail_with('plugin_point_unknown', 'no such point: ' . $point,
                      ['point' => $point]);
        }
        $this->entry->bindings[] = ['ref' => $this->ref, 'point' => $point,
                                    'fn' => $fn, 'band' => $band ?? 0];
    }

    /** Published for other plugins and for the application (§11). */
    public function export(string $key, $value): void
    {
        $this->entry->exports[$key] = $value;
    }

    /** What this instance can do for others (§11.1). */
    public function provides(array $prov): void
    {
        $this->entry->provides[] = $prov;
    }

    /**
     * Where this binding landed (§6.6) - the plugin-side counterpart to a
     * host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
     * available. Verification tells a plugin it was misplaced; a pin (§7)
     * stops the misplacement from being expressible at all. The two are
     * not substitutes.
     *
     * @return array<string,mixed>
     */
    public function position(?string $point): array
    {
        return $this->hostref->positionof($this->ref, $point);
    }

    /**
     * AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
     * INNER ONE'S LIFETIME. Registering the teardown in the instance scope
     * is what makes that true rather than aspirational.
     */
    public function nest(?array $nestopts = null): Host
    {
        if (!$this->hostref->intransition()) {
            fail_with('plugin_release_scope',
                      'nest called outside a lifecycle callback');
        }
        $inner = new Host($nestopts);
        $this->entry->scope[] = static function () use ($inner) {
            $inner->close();
        };
        $this->entry->inner = $inner;
        return $inner;
    }
}

class Host
{
    public Catalog $catalog;

    /** @var array<string,mixed> */
    private array $opts;

    private string $dependency;

    /** Set for the duration of a bulk teardown, so `held` knows this is a
     * coordinated operation rather than an ad-hoc deactivation. */
    private bool $coordinated = false;

    /** @var string[] */
    private array $reserved;

    /** @var array<string,mixed> */
    private array $points;

    /** @var array<string,Entry> */
    private array $inst = [];

    /** @var string[] */
    private array $log = [];

    /**
     * §14: the lifecycle event record. `seq` distinguishes ONE INCARNATION
     * of stripe$test from the next, which is the whole reason it is not
     * `pos` (§4 rule 4).
     *
     * @var array<int,array<string,mixed>>
     */
    private array $events = [];

    private int $seqn = 0;

    private int $open = 0;

    private bool $transitioning = false;

    /**
     * WHICH callback is running, not merely that one is. §8.1 puts
     * resource capture in `activate` and 8.3 says `release` outside
     * `activate` is `plugin_release_scope` - and a flag alone cannot tell
     * `activate` from `define`, so it admitted an acquire in `define`
     * whose scope `unload` would never unwind.
     */
    private ?string $phase = null;

    public function __construct(?array $options = null)
    {
        $this->opts = $options ?? [];
        // `??` covers both an absent key and an explicit null, which is
        // what a driver passing an unset command field hands over.
        $this->dependency = $this->opts['dependency'] ?? 'restart';
        $this->catalog = $this->opts['catalog'] ?? make_catalog();
        $this->reserved = $this->opts['reserved'] ?? [];
        $this->points = $this->opts['points'] ?? [];
    }

    public function intransition(): bool
    {
        return $this->transitioning;
    }

    public function phase(): ?string
    {
        return $this->phase;
    }

    public function haspoint(string $name): bool
    {
        return array_key_exists($name, $this->points);
    }

    public function open_inc(): void
    {
        $this->open++;
    }

    public function open_dec(): void
    {
        $this->open--;
    }

    // --- observation ------------------------------------------------

    /**
     * Introspection NEVER advances the state (§5.2). A status page must
     * not be a way to accidentally import twenty packages.
     *
     * @return array<string,string>
     */
    public function list(): array
    {
        $out = [];
        foreach (Util::sortedkeys($this->inst) as $r) {
            $out[$r] = $this->inst[$r]->status;
        }
        return $out;
    }

    public function instance($ref): ?Entry
    {
        return $this->inst[canon_ref($ref)] ?? null;
    }

    /** @return array<int,array<string,mixed>> */
    public function trace(): array
    {
        return $this->events;
    }

    /**
     * @param mixed $result
     * @return array<string,mixed>
     */
    public function observable($result = null): array
    {
        return ['status' => $this->list(), 'open' => $this->open,
                'log' => $this->log, 'result' => $result];
    }

    // --- the state machine ------------------------------------------

    public function guard(): void
    {
        if (!$this->transitioning) {
            return;
        }
        fail_with('plugin_reentrant',
                  'transition attempted from inside a lifecycle callback');
    }

    private function need($ref): Entry
    {
        $r = canon_ref($ref);
        $entry = $this->inst[$r] ?? null;
        if (null === $entry) {
            fail_with('plugin_not_loaded', 'no such instance: ' . $r, ['ref' => $r]);
        }
        return $entry;
    }

    private function checkreserved(string $ref): void
    {
        if (empty($this->reserved)) {
            return;
        }
        if (!in_array(refname($ref), $this->reserved, true)) {
            return;
        }
        fail_with('plugin_ref_reserved', 'ref is reserved by the host: ' . $ref,
                  ['ref' => $ref]);
    }

    private function run(Entry $entry, string $callback, string $at): void
    {
        $fn = $entry->def[$callback] ?? null;
        $this->log[] = $entry->ref . ':' . $at;
        $this->events[] = ['ref' => $entry->ref, 'event' => $at,
                           'seq' => $entry->seq, 'status' => $entry->status];
        if (!is_callable($fn)) {
            return;
        }

        $this->transitioning = true;
        $this->phase = $at;
        try {
            $fn(new Inst($this, $entry));
        } catch (\Throwable $e) {
            // §12: `plugin_define_failed` and its three siblings are "a
            // callback raised; wraps the cause". AN ERROR THAT ALREADY
            // CARRIES A CODE KEEPS IT - the code is the error's identity,
            // and a plugin raising `store_unreachable` must not have it
            // rewritten. Only a code-less error is wrapped.
            if ('' !== codeof($e)) {
                throw $e;
            }
            fail_with('plugin_' . $at . '_failed',
                      $entry->ref . ' raised in ' . $at . ': ' . $e->getMessage(),
                      ['ref' => $entry->ref, 'cause' => $e->getMessage()]);
        } finally {
            $this->transitioning = false;
            $this->phase = null;
        }
    }

    /**
     * AUTO-TAGGING IS EXPLICIT (§4 rule 3). `declare('stripe', ['tag' =>
     * '?'])` assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns
     * the assigned pair. Without `'?'`, a collision is an error.
     */
    private function autotag(string $name): string
    {
        $n = 1;
        while (true) {
            $cand = format_ref($name, (string)$n);
            if (!array_key_exists($cand, $this->inst)) {
                return $cand;
            }
            $n++;
        }
    }

    /**
     * @param array<string,mixed>|null $spec
     */
    public function declare($ref, ?array $spec = null): Entry
    {
        $spec = $spec ?? [];
        if ('?' === ($spec['tag'] ?? null)) {
            $ref = $this->autotag(refname(canon_ref($ref)));
        }
        $r = canon_ref($ref);
        if (!Util::truthy($spec['hostowned'] ?? null)) {
            $this->checkreserved($r);
        }
        $defname = $spec['definition'] ?? refname($r);
        $definition = $this->catalog->get($defname);
        if (null === $definition) {
            fail_with('plugin_unknown_definition', 'not in catalog: ' . $defname,
                      ['name' => $defname]);
        }

        $existing = $this->inst[$r] ?? null;
        if (null !== $existing) {
            // §4 rule 1: a pair addresses at most one instance.
            // Re-declaring the SAME definition is the idempotent case; a
            // different one is a duplicate, not a silent overwrite
            // (seneca) and not an impossibility (sdkgen).
            if ($existing->def['name'] !== $definition['name']) {
                fail_with('plugin_ref_duplicate', 'instance already declared: ' . $r,
                          ['ref' => $r]);
            }
            return $existing;
        }

        $entry = new Entry($r, $definition);
        $entry->pos = null === ($spec['pos'] ?? null)
            ? count($this->inst) : $spec['pos'];
        $entry->seq = $this->seqn;
        $entry->options = $spec['options'] ?? [];
        $entry->order = $spec['order'] ?? null;
        $this->seqn++;
        $this->inst[$r] = $entry;
        return $entry;
    }

    /**
     * §9.1: a host that reserves a name MUST still be able to declare the
     * instance it reserved - "The host declares those instances itself,
     * after the user merge, and always wins."
     *
     * THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit:
     * no language here can tell the embedding host from a plugin holding
     * the same host object. What reservation protects is CONFIGURATION -
     * documents, overlays, `VOXGIG_PLUGIN_*`, construction options and
     * ordinary declare/load/options - and all of that still checks.
     */
    public function hostdeclare($ref, ?array $spec = null): Entry
    {
        $this->guard();
        $spec = $spec ?? [];
        $spec['hostowned'] = true;
        return $this->declare($ref, $spec);
    }

    public function load($ref, ?array $spec = null): Entry
    {
        $this->guard();
        $spec = $spec ?? [];
        $entry = $this->declare($ref, $spec);
        if ('declared' !== $entry->status) {
            return $entry;                    // idempotent trivially
        }

        // PRESENCE, NOT TRUTH. An empty options map must CLEAR what the
        // instance was declared with, and `if ($spec['options'])` is false
        // for `[]` in PHP - which would keep options a document just
        // removed.
        if (null !== ($spec['options'] ?? null)) {
            $entry->options = $spec['options'];
        }
        try {
            $this->run($entry, 'define', 'define');
        } catch (\Throwable $e) {
            $entry->status = 'failed';
            throw $e;
        }
        $entry->status = 'loaded';

        // AT LOAD, and before anything runs: a cycle through
        // restart-causing requirements does not settle, and the only safe
        // time to report a non-terminating reconcile is before it starts
        // (§11.3). `provides` is populated by `define`, which has just
        // run, so this is the first moment the graph is complete.
        try {
            checkcycle($this->graphnodes());
        } catch (\Throwable $e) {
            $entry->status = 'failed';
            throw $e;
        }
        return $entry;
    }

    /**
     * The requirement graph as plain data, for the pure detector.
     *
     * @return array<int,array<string,mixed>>
     */
    private function graphnodes(): array
    {
        $out = [];
        foreach (Util::sortedkeys($this->inst) as $r) {
            $entry = $this->inst[$r];
            $provides = [];
            foreach ($entry->provides as $p) {
                $provides[] = $p['name'];
            }
            $out[] = ['ref' => $r, 'provides' => $provides,
                      'requires' => requirements($entry->options)];
        }
        return $out;
    }

    public function activate($ref): Entry
    {
        $this->guard();
        $entry = $this->need($ref);
        if ('live' === $entry->status) {
            return $entry;                    // no-op returning success
        }

        if ('failed' === $entry->status) {
            fail_with('plugin_bad_state', 'instance has failed: ' . $entry->ref,
                      ['ref' => $entry->ref]);
        }
        // §9.6: `active: false` bars the instance from running, and the
        // bar is on the INSTANCE rather than on the apply that set it.
        // `ready` reaches this through `activate`, so one guard covers
        // both verbs the design names.
        if ($entry->barred) {
            fail_with('plugin_inactive',
                      'instance is barred by active: false: ' . $entry->ref,
                      ['ref' => $entry->ref]);
        }
        if ('declared' === $entry->status) {
            $this->load($entry->ref);
        }

        // A declared requirement that is not live means `pending`:
        // activation is a STANDING REQUEST, not a one-shot event.
        $unmet = $this->unmetof($entry);
        if (!empty($unmet)) {
            $entry->unmet = $unmet;
            $entry->status = 'pending';
            return $entry;
        }

        try {
            $this->run($entry, 'activate', 'activate');
        } catch (\Throwable $e) {
            // Unwind whatever the partial activation captured, in reverse.
            $this->unwind($entry);
            $entry->status = 'failed';
            throw $e;
        }
        // §11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
        // later question - the cascade, `hold`, `unmet` - reads it back
        // rather than re-ranking, which is what "always-reluctant" means.
        foreach (requirements($entry->options) as $req) {
            $this->chosen($entry, $req, true);
        }
        $entry->status = 'live';
        $this->reconcile();
        return $entry;
    }

    public function deactivate($ref): Entry
    {
        $this->guard();
        $entry = $this->need($ref);
        if (in_array($entry->status, ['loaded', 'declared'], true)) {
            return $entry;
        }

        // §5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
        if ('failed' === $entry->status) {
            fail_with('plugin_bad_state', 'instance has failed: ' . $entry->ref,
                      ['ref' => $entry->ref]);
        }

        if ('pending' === $entry->status) {
            // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It
            // never reached activate, so it holds no scope and no live
            // bindings; running the definition's deactivate there would be
            // teardown without matching setup, which plugins are not
            // written to survive and which could fail an instance that had
            // done nothing wrong. It cannot fail.
            $entry->status = 'loaded';
            $entry->unmet = [];
            return $entry;
        }

        $this->held($entry);
        $this->cascade($entry, new Bag());

        try {
            $this->run($entry, 'deactivate', 'deactivate');
        } catch (\Throwable $e) {
            $this->unwind($entry);
            $entry->status = 'failed';
            throw $e;
        }
        $this->releasecheck($entry, $this->unwind($entry));
        $entry->status = 'loaded';
        $this->reconcile();
        return $entry;
    }

    public function unload($ref): void
    {
        $this->guard();
        $entry = $this->need($ref);
        if (in_array($entry->status, ['live', 'pending'], true)) {
            if ('live' === $entry->status) {
                $this->held($entry);
                $this->cascade($entry, new Bag());
                try {
                    $this->run($entry, 'deactivate', 'deactivate');
                } catch (\Throwable $e) {
                    // §5.2: ANY failure during a transition lands the
                    // instance in `failed`, with the scope STILL FULLY
                    // UNWOUND - and the instance STAYS REGISTERED, because
                    // `failed` is a state an operator has to be able to
                    // see.
                    $this->unwind($entry);
                    $entry->status = 'failed';
                    throw $e;
                }
                $this->releasecheck($entry, $this->unwind($entry));
            }
            $entry->status = 'loaded';
        }
        if (in_array($entry->status, ['loaded', 'failed'], true)) {
            try {
                $this->run($entry, 'close', 'close');
            } finally {
                unset($this->inst[$entry->ref]);
            }
            return;
        }
        unset($this->inst[$entry->ref]);
    }

    /** Runs the whole forward path in one call (§5.1). */
    public function ready($ref): Entry
    {
        $this->guard();
        $r = canon_ref($ref);
        if (!array_key_exists($r, $this->inst)) {
            $this->declare($r);
        }
        if ('declared' === $this->inst[$r]->status) {
            $this->load($r);
        }
        return $this->activate($r);
    }

    /**
     * Bindings go live only when activation succeeds (§8.1), so the
     * teardown is the exact inverse: reverse order, always. Returns the
     * errors the scope raised. §8.3: "A failing release does not stop the
     * rest. Every entry runs, in reverse order, whatever any of them does;
     * the errors are collected and raised as one `plugin_release_failed`."
     *
     * A selection belongs to ONE activation (§11.4). Leaving `live` by any
     * door drops it, so the next activation ranks afresh - keeping it
     * would make a consumer prefer a provider it never actually ran
     * against.
     *
     * @return array<int,\Throwable>
     */
    private function unwind(Entry $entry): array
    {
        $entry->selected = [];
        $errors = [];
        foreach (array_reverse($entry->scope) as $fn) {
            try {
                $fn();
            } catch (\Throwable $e) {
                $errors[] = $e;
            }
        }
        $entry->scope = [];
        return $errors;
    }

    /**
     * §8.3: "A failed release ends the instance in `failed`, exactly as a
     * failed callback does (5.2) - a release that raised may have leaked,
     * and an instance that may be holding resources it cannot account for
     * must not be reactivated."
     *
     * @param array<int,\Throwable> $errors
     */
    private function releasecheck(Entry $entry, array $errors): void
    {
        if (empty($errors)) {
            return;
        }

        $entry->status = 'failed';
        $causes = [];
        foreach ($errors as $e) {
            $causes[] = $e->getMessage();
        }
        fail_with('plugin_release_failed',
                  'release failed for ' . $entry->ref . ': '
                  . implode('; ', $causes),
                  ['ref' => $entry->ref, 'cause' => $causes]);
    }

    /**
     * A REQUIREMENT IS ON A CAPABILITY, not on a ref (§11.1). A bare
     * string is shorthand for `{name}`. A ref satisfies too, because a
     * host that genuinely needs a specific instance should not have to
     * invent a capability for it.
     *
     * @return string[]
     */
    private function unmetof(Entry $entry): array
    {
        $out = [];
        foreach (requirements($entry->options) as $req) {
            if (!gatesactivation($req)) {
                continue;
            }
            if (!empty($this->providersof($req))) {
                continue;
            }
            $out[] = $req['name'];
        }
        return $out;
    }

    /**
     * §11.4's always-reluctant selection, and the ONE place a provider is
     * picked for a live instance. If this instance already selected a
     * provider for `req` and that provider is STILL a candidate, it keeps
     * it - a better-ranked newcomer does not take it.
     *
     * `remember` is false for the questions asked ABOUT an instance rather
     * than BY it: introspection must not create a binding.
     *
     * @param array<string,mixed> $req
     */
    private function chosen(Entry $entry, array $req, bool $remember): ?string
    {
        $cands = $this->providersof($req);
        if (empty($cands)) {
            return null;
        }

        $held = $entry->selected[$req['name']] ?? null;
        if (null !== $held) {
            foreach ($cands as $c) {
                if ($c['ref'] === $held) {
                    return $held;
                }
            }
        }

        if ($remember) {
            $entry->selected[$req['name']] = $cands[0]['ref'];
        }
        return $cands[0]['ref'];
    }

    /** @return string[] */
    private function boundproviders(Entry $entry): array
    {
        $out = [];
        foreach (requirements($entry->options) as $req) {
            if (!restartsonloss($req)) {
                continue;
            }
            $ref = $this->chosen($entry, $req, false);
            if (null !== $ref && !in_array($ref, $out, true)) {
                $out[] = $ref;
            }
        }
        return $out;
    }

    /**
     * Live instances whose selected provider is `ref` and which would be
     * restarted by losing it.
     *
     * @return string[]
     */
    private function consumersof(string $ref): array
    {
        $out = [];
        foreach (Util::sortedkeys($this->inst) as $r) {
            $c = $this->inst[$r];
            if ($r !== $ref && 'live' === $c->status
                && in_array($ref, $this->boundproviders($c), true)) {
                $out[] = $r;
            }
        }
        return $out;
    }

    /**
     * §11.3's `hold` asks a DIFFERENT question from the cascade, and
     * reading it off `consumersof` answered the cascade's.
     *
     * The cascade wants the edges that RESTART - mandatory-static and
     * optional-static - because a restart is what it performs. `hold` says
     * "deactivating a REQUIRED instance is `plugin_dependency_held`", and
     * required is cardinality: `gatesactivation`, not `restartsonloss`.
     * The two sets differ in both directions and each difference was a
     * real bug.
     *
     * A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy
     * let a provider go that a live consumer could not do without -
     * `dynamic` promises survival of a SWAP, and under `hold` there is no
     * swap, so the consumer falls back to `pending`.
     *
     * An OPTIONAL-STATIC consumer was included, so `hold` refused a
     * deactivation on behalf of an instance that had said in writing it
     * does not need the thing.
     *
     * @return string[]
     */
    private function holdersof(string $ref): array
    {
        $out = [];
        foreach (Util::sortedkeys($this->inst) as $r) {
            $c = $this->inst[$r];
            if ($r === $ref || 'live' !== $c->status) {
                continue;
            }
            foreach (requirements($c->options) as $req) {
                if (!gatesactivation($req)) {
                    continue;
                }
                if ($this->chosen($c, $req, false) === $ref) {
                    $out[] = $r;
                    break;
                }
            }
        }
        return $out;
    }

    /**
     * @param array<string,mixed> $req
     * @return array<int,array<string,mixed>>
     */
    private function providersof(array $req): array
    {
        $cands = [];
        $want = canon($req['name']);
        foreach (Util::sortedkeys($this->inst) as $ref) {
            $target = $this->inst[$ref];
            if ('live' !== $target->status) {
                continue;
            }

            // A ref satisfies directly.
            if ($ref === $want) {
                $cands[] = ['ref' => $ref, 'pos' => $target->pos,
                            'provides' => ['name' => $req['name']]];
                continue;
            }
            foreach ($target->provides as $prov) {
                if (($prov['name'] ?? null) === $req['name']) {
                    $cands[] = ['ref' => $ref, 'pos' => $target->pos,
                                'provides' => $prov];
                }
            }
        }
        return resolve_capability($req, $cands);
    }

    /**
     * CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
     *
     * The cascade is part of the provider's own deactivation and runs
     * BEFORE the provider's `deactivate` callback and scope unwind, so a
     * consumer's teardown can still call the thing it depends on -
     * flushing a buffer to the store it is about to lose is exactly what a
     * `deactivate` callback is for, and a cascade that fired after the
     * provider was already gone would make that impossible.
     *
     * `$seen` is a `Bag` and not an array because the recursion has to
     * share ONE set of visited refs, and a PHP array passed down would be
     * a copy per frame.
     */
    private function cascade(Entry $provider, Bag $seen): void
    {
        if ($seen[$provider->ref] ?? false) {
            return;
        }

        $seen[$provider->ref] = true;

        foreach ($this->consumersof($provider->ref) as $r) {
            $consumer = $this->inst[$r];
            if ('live' !== $consumer->status) {
                continue;
            }

            $this->cascade($consumer, $seen);   // deepest-first
            $bad = false;
            try {
                $this->run($consumer, 'deactivate', 'deactivate');
            } catch (\Throwable $e) {
                $bad = true;
            }
            $errors = $this->unwind($consumer);
            if ($bad || !empty($errors)) {
                // §5.2: ANY failure during a transition lands the instance
                // in `failed`. Marking it `pending` handed it straight
                // back to `reconcile`, which would activate it again the
                // moment the provider returned.
                $consumer->status = 'failed';
                continue;
            }
            $consumer->status = 'pending';
            $consumer->unmet = $this->unmetof($consumer);
        }
    }

    /**
     * The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
     * TEARDOWN. In a bulk operation that is removing the holders too -
     * `close`, or an `apply` plan whose own steps deactivate them - it is
     * suspended for exactly those holders, and the teardown still runs
     * consumers before providers.
     */
    private function held(Entry $entry): void
    {
        if ('hold' !== $this->dependency) {
            return;
        }
        if ($this->coordinated) {
            return;
        }

        $holders = $this->holdersof($entry->ref);
        if (empty($holders)) {
            return;
        }

        fail_with('plugin_dependency_held',
                  'instance is required by live consumers: ' . $entry->ref,
                  ['ref' => $entry->ref, 'holders' => $holders]);
    }

    /**
     * EAGER reconciliation: run to a fixed point rather than scheduling.
     *
     * Two directions, and both are the reason `pending` exists. Activation
     * is a STANDING REQUEST, not a one-shot event.
     */
    private function reconcile(): void
    {
        $moved = true;
        $rounds = 0;
        while ($moved) {
            $moved = false;
            $rounds++;
            if ($rounds > 1000) {
                break;
            }

            // Losses first, so a cascade settles in one pass rather than
            // alternating with re-activations.
            foreach (Util::sortedkeys($this->inst) as $r) {
                $entry = $this->inst[$r];
                if ('live' !== $entry->status) {
                    continue;
                }

                $lost = [];
                foreach (requirements($entry->options) as $q) {
                    if (!gatesactivation($q)) {
                        continue;
                    }
                    if (empty($this->providersof($q))) {
                        $lost[] = $q;
                    }
                }
                if (empty($lost)) {
                    continue;
                }
                // POLICY IS PER REQUIREMENT, not per instance (§11.3). A
                // `dynamic` requirement whose provider is gone leaves the
                // consumer LIVE and notified.
                $restarts = false;
                foreach ($lost as $q) {
                    if (restartsonloss($q)) {
                        $restarts = true;
                        break;
                    }
                }
                if (!$restarts) {
                    continue;
                }

                $bad = false;
                try {
                    $this->run($entry, 'deactivate', 'deactivate');
                } catch (\Throwable $e) {
                    $bad = true;
                }
                $errors = $this->unwind($entry);
                if ($bad || !empty($errors)) {
                    $entry->status = 'failed';
                    $moved = true;
                    continue;
                }
                $entry->status = 'pending';
                $entry->unmet = $this->unmetof($entry);
                $moved = true;
            }

            foreach (Util::sortedkeys($this->inst) as $r) {
                $entry = $this->inst[$r];
                if ('pending' !== $entry->status) {
                    continue;
                }
                if (!empty($this->unmetof($entry))) {
                    continue;
                }

                try {
                    $this->run($entry, 'activate', 'activate');
                    $entry->status = 'live';
                    $entry->unmet = [];
                    $moved = true;
                } catch (\Throwable $e) {
                    $this->unwind($entry);
                    $entry->status = 'failed';
                    $moved = true;
                }
            }
        }
    }

    // --- ordering ---------------------------------------------------

    /** @return string[] */
    public function order(?string $point = null): array
    {
        // Sorted by declaration SEQUENCE, which is what makes the §7
        // sort's fall-through deterministic in a language whose maps have
        // no insertion order. §7 breaks ties by `pos`; two instances CAN
        // share one - `declare` defaults `pos` to the registry size, so an
        // unload followed by a fresh declare reuses a surviving instance's
        // - and past that this was falling through to hash order. `seq` is
        // that order, made explicit.
        $live = [];
        foreach ($this->inst as $r => $entry) {
            if ('live' === $entry->status) {
                $live[] = $entry;
            }
        }
        $live = Util::stable_sort_by($live, static function (Entry $e) {
            return [$e->seq];
        });
        $bindings = [];
        foreach ($live as $entry) {
            $bindings[] = ['ref' => $entry->ref, 'pos' => $entry->pos,
                           'order' => $entry->order];
        }
        $spec = null === $point ? null : ($this->points[$point] ?? null);
        $pin = is_array($spec) ? ($spec['pin'] ?? null) : null;
        return resolve_order($bindings, $pin);
    }

    // --- points -----------------------------------------------------

    /**
     * Live bindings on a point, in resolved order. Recomputed on any
     * change to the live set (§7) rather than cached at startup - the bug
     * a host discovers only when something deactivates in production.
     *
     * @return array<int,array<string,mixed>>
     */
    private function bound(string $point): array
    {
        $out = [];
        foreach ($this->order($point) as $ref) {
            $entry = $this->inst[$ref];
            // The band is the INSTANCE's ordering block (§7), stamped by
            // the host. A plugin passing its own would be ranking itself
            // above the order its document declared.
            $block = is_array($entry->order) ? $entry->order : [];
            $band = is_int($block['band'] ?? null) ? $block['band'] : 0;
            foreach ($entry->bindings as $b) {
                if ($b['point'] === $point) {
                    $b['band'] = $band;
                    $out[] = $b;
                }
            }
        }
        return $out;
    }

    /**
     * @return array<string,mixed>
     */
    private function pointspec(string $point, string $want): array
    {
        $spec = $this->points[$point] ?? null;
        if (null === $spec) {
            fail_with('plugin_point_unknown', 'no such point: ' . $point,
                      ['point' => $point]);
        }
        $kind = $spec['kind'] ?? null;
        if ('hook' === $want) {
            // A point with no declared kind is a hook, which is what makes
            // `{}` the minimal point declaration.
            if (null !== $kind && 'hook' !== $kind) {
                fail_with('plugin_point_kind', 'point is not a hook: ' . $point,
                          ['point' => $point, 'kind' => $kind]);
            }
            return $spec;
        }
        if ($kind !== $want) {
            fail_with('plugin_point_kind', 'point is not a ' . $want . ': ' . $point,
                      ['point' => $point, 'kind' => $kind]);
        }
        return $spec;
    }

    /**
     * @param mixed $arg
     * @return mixed
     */
    public function emit(string $point, $arg = null)
    {
        $spec = $this->pointspec($point, 'hook');
        return point_emit($this->bound($point), $spec['mode'] ?? 'emit', $arg);
    }

    /** @return mixed */
    public function call(string $point, ...$args)
    {
        $spec = $this->pointspec($point, 'chain');
        $base = $spec['base'] ?? static function (...$a) {
            return $a[0] ?? null;
        };
        $fn = compose($this->bound($point), $base);
        return $fn(...$args);
    }

    /** @return mixed */
    public function provider(string $point, ...$args)
    {
        $spec = $this->pointspec($point, 'provider');
        $pick = point_provider($this->bound($point), $spec);
        if (null === $pick['winner']) {
            return $spec['default'] ?? null;
        }
        return ($pick['winner']['fn'])(...$args);
    }

    /**
     * The losers are VISIBLE rather than silently ignored (§6.3).
     *
     * @return string[]
     */
    public function shadowed(string $point): array
    {
        $spec = $this->points[$point] ?? null;
        if (null === $spec) {
            return [];
        }
        return point_provider($this->bound($point), $spec)['shadowed'];
    }

    /** @return mixed */
    public function exports(string $spec)
    {
        $all = [];
        foreach (Util::sortedkeys($this->inst) as $ref) {
            $entry = $this->inst[$ref];
            // Exports of a `loaded` (not live) instance are VISIBLE (§11).
            if (in_array($entry->status, ['declared', 'failed'], true)) {
                continue;
            }
            foreach (Util::sortedkeys($entry->exports) as $k) {
                $all[] = ['ref' => $ref, 'key' => $k,
                          'value' => $entry->exports[$k]];
            }
        }
        return resolve_export($spec, $all);
    }

    /**
     * The live providers of a capability, best-first (§11.1).
     *
     * @return string[]
     */
    public function capability(string $name): array
    {
        $cands = [];
        foreach (Util::sortedkeys($this->inst) as $ref) {
            $entry = $this->inst[$ref];
            if ('live' !== $entry->status) {
                continue;
            }
            foreach ($entry->provides as $prov) {
                if (($prov['name'] ?? null) === $name) {
                    $cands[] = ['ref' => $ref, 'pos' => $entry->pos,
                                'provides' => $prov];
                }
            }
        }
        $out = [];
        foreach (resolve_capability(['name' => $name], $cands) as $c) {
            $out[] = $c['ref'];
        }
        return $out;
    }

    // --- documents --------------------------------------------------

    /**
     * §9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
     * changed, and move activation state to match", with the stated
     * ordering - "deactivations and unloads first (reverse load order),
     * then loads, then activations in load order".
     *
     * FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
     * document once, which never looked at instances the new document had
     * DROPPED - so an integration removed from a config reload stayed live
     * with its bindings and resources.
     *
     * @param array<string,mixed>|null $doc
     */
    public function apply(?array $doc, ?string $profile = null): void
    {
        $this->guard();
        $profile = $profile ?? ($this->opts['profile'] ?? null);
        $norm = normalize_config(['doc' => $doc, 'profile' => $profile,
                                  'keys' => $this->opts['keys'] ?? null,
                                  'reserved' => $this->reserved]);

        $want = $norm['order'];
        $defaults = $this->opts['defaults'] ?? [];
        $optionsof = [];
        foreach ($want as $ref) {
            $optionsof[$ref] = resolve_options(
                ['ref' => $ref, 'doc' => $doc, 'profile' => $profile,
                 'shape' => $this->shapeof($ref),
                 'hostdefaults' => $defaults[refname($ref)] ?? null]
            );
        }

        // Should this ref be LIVE after the apply? False for a ref the
        // document declares lazy or inactive AND for one it does not name
        // at all - which is what makes "unload what is gone" and "unload
        // what was toggled off" one rule rather than two.
        $wantlive = static function (string $ref) use ($norm): bool {
            $ent = $norm['instance'][$ref] ?? null;
            return null !== $ent && Util::truthy($ent['active'])
                && 'eager' === $ent['start'];
        };

        // --- phase 1: deactivations and unloads, REVERSE load order ----
        $drop = [];
        foreach (array_keys($this->inst) as $r) {
            if ('declared' === $this->inst[$r]->status || $wantlive($r)) {
                continue;
            }
            $drop[] = $r;
        }
        // Highest `pos` first, ref-descending for a tie, so a consumer
        // declared after its provider goes down first. (Ruby spells the
        // tie as a sort-then-reverse-each-run; this is the comparator that
        // spelling adds up to.)
        $inst = $this->inst;
        usort($drop, static function ($a, $b) use ($inst) {
            if ($inst[$a]->pos !== $inst[$b]->pos) {
                return $inst[$b]->pos <=> $inst[$a]->pos;
            }
            return strcmp($b, $a);
        });
        foreach ($drop as $ref) {
            $this->unload($ref);
        }

        // --- phase 2: declare and patch EVERYTHING, in load order ------
        foreach ($want as $ref) {
            $ent = $norm['instance'][$ref];
            $this->declare($ref, ['options' => $optionsof[$ref],
                                  'order' => $ent['order'] ?? null,
                                  'pos' => $ent['pos']]);
            // The bar is REASSERTED ON EVERY APPLY, in both directions - a
            // document that turns the instance back on clears it, which is
            // the whole point of a config switch.
            $this->inst[$ref]->barred = !Util::truthy($ent['active']);
            // REPLACE rather than refill. Ruby empties the options hash in
            // place because a definition's callbacks close over the map
            // they were handed at `define`; PHP's arrays are values, so no
            // callback can be holding this one - `Inst::options()` reads it
            // back through the entry every time, which is the same
            // observable behaviour by a shorter road.
            $this->refill($this->inst[$ref], $optionsof[$ref]);
            $this->inst[$ref]->order = $ent['order'] ?? null;
            $this->inst[$ref]->pos = $ent['pos'];
        }

        // --- phase 3: loads, in load order -----------------------------
        // ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy
        // instances is twenty map entries and no executed code" (§9.6).
        foreach ($want as $ref) {
            if ($wantlive($ref)) {
                $this->load($ref);
            }
        }

        // --- phase 4: activations, in load order -----------------------
        foreach ($want as $ref) {
            if ($wantlive($ref)) {
                $this->activate($ref);
            }
        }
    }

    /** @return array<string,mixed>|null */
    private function shapeof(string $ref): ?array
    {
        $definition = $this->catalog->get(refname($ref));
        return null === $definition ? null : ($definition['shape'] ?? null);
    }

    /**
     * @param array<string,mixed>|null $patch
     */
    public function options($ref, ?array $patch): void
    {
        $this->guard();
        $entry = $this->need($ref);
        $previous = $entry->options;
        $merged = $previous;
        foreach ($patch ?? [] as $k => $v) {
            $merged[$k] = $v;
        }
        $this->refill($entry, resolve_options(
            ['ref' => $entry->ref, 'shape' => $this->shapeof($entry->ref),
             'doc' => [], 'patch' => $merged]
        ));
        if ('live' !== $entry->status) {
            return;
        }

        $reconfigure = $entry->def['reconfigure'] ?? null;
        if (is_callable($reconfigure)) {
            $this->transitioning = true;
            try {
                $reconfigure(new Inst($this, $entry), $entry->options, $previous);
            } finally {
                $this->transitioning = false;
            }
        } else {
            // Always correct and sometimes expensive; `reconfigure` exists
            // to make the common case cheap (§9.4).
            $this->deactivate($entry->ref);
            $this->activate($entry->ref);
        }
    }

    /**
     * @param array<string,mixed>|null $source
     */
    private function refill(Entry $entry, ?array $source): void
    {
        $entry->options = $source ?? [];
    }

    public function close(): void
    {
        // A bulk teardown removing the holders too, so `hold` is suspended
        // for exactly those holders (§11.3) - while the consumers-first
        // cascade still runs, which is the half that matters.
        $this->coordinated = true;
        try {
            foreach (array_reverse(Util::sortedkeys($this->inst)) as $r) {
                $this->unload($r);
            }
        } finally {
            $this->coordinated = false;
        }
    }

    /**
     * The same record §6.6 gives a plugin about itself, reachable from
     * outside for the corpus.
     *
     * @return array<string,mixed>
     */
    public function positionof($ref, ?string $point): array
    {
        $entry = $this->inst[canon($ref)] ?? null;
        if (null === $entry) {
            fail_with('plugin_not_loaded', 'no such instance: ' . $ref,
                      ['ref' => $ref]);
        }
        $ranked = $this->order($point);
        $index = array_search($entry->ref, $ranked, true);
        $index = false === $index ? -1 : (int)$index;
        return ['index' => $index, 'count' => count($ranked),
                // §6.2 composes b1(b2(b3(base))) with the FIRST binding
                // OUTERMOST, so these are not index 0 and index count-1
                // the other way round.
                'outermost' => 0 === $index,
                'innermost' => $index === count($ranked) - 1];
    }

    public function define(array $definition): void
    {
        $this->catalog->add($definition);
    }
}

function make_host(?array $options = null): Host
{
    return new Host($options);
}
