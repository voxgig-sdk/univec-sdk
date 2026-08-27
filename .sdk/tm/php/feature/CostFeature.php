<?php
declare(strict_types=1);

// Univec SDK cost feature

require_once __DIR__ . '/BaseFeature.php';

// Cost tracking and spend budget. Uses BOTH seams, which is the point of
// the feature: money is spent per HTTP ATTEMPT (a retried call is charged
// again, because the upstream API charges it again), but it is owed by an
// OPERATION. So the transport wrap prices each attempt, and PreDone
// attributes the running total to `<entity>.<op>` and to the caller
// (`ctrl->actor`, the same actor the audit feature records).
//
// The price of an attempt comes from the first source that answers: a
// response header (`header` x `perUnit`), the rate table (`rates`, keyed
// `<entity>.<op>` / `<op>` / `*`), then the flat `unit`. A body figure
// (`path` x `perUnit`, e.g. 'usage.total_tokens') is read at PreDone
// instead, from the already-parsed result, and describes the whole call, so
// it REPLACES the per-attempt estimate rather than adding to it.
//
// `budget` caps total spend. With `onBudget: 'deny'` a further operation is
// refused at PrePoint (the error is placed in `$ctx->out['point']`), before
// an endpoint is resolved and before anything reaches the network.
//
// ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
// cache is charged for money that was never spent. The default (map) order
// puts cache innermost and cost outside it, so activate them in list form
// with cost first. Mirrors ts/src/feature/cost/CostFeature.ts.
class UnivecCostFeature extends UnivecBaseFeature
{
    private mixed $client;
    private ?array $options;
    private ?\WeakMap $pending;
    private int $seq;

    public function __construct()
    {
        parent::__construct();
        $this->version = '0.0.1';
        $this->name = 'cost';
        $this->active = true;
        $this->client = null;
        $this->options = null;
        $this->pending = null;
        $this->seq = 0;
    }

    public function init(UnivecContext $ctx, array $options): void
    {
        $this->client = $ctx->client;
        $this->options = $options;
        $this->active = ($options['active'] ?? null) === true;
        $this->pending = new \WeakMap();
        $this->seq = 0;

        $limit = $this->_limit();

        $client = $this->client;
        if (!isset($client->_cost)) {
            $client->_cost = [
                'currency' => (string)($this->options['currency'] ?? 'USD'),
                'total' => [
                    'calls' => 0, 'attempts' => 0,
                    'amount' => 0.0, 'reported' => 0.0, 'estimated' => 0.0,
                ],
                'ops' => [],
                'actors' => [],
                'budget' => [
                    'limit' => $limit, 'spent' => 0.0,
                    'remaining' => $limit, 'exceeded' => false,
                ],
                'last' => null,
            ];
        }

        if (!$this->active) {
            return;
        }

        $utility = $ctx->utility;
        $inner = $utility->fetcher;

        $utility->fetcher = function (UnivecContext $ctx2, string $url, array $fetchdef) use ($inner): array {
            return $this->_charge($ctx2, $url, $fetchdef, $inner);
        };
    }

    // The budget gate. Runs before endpoint resolution, so a refused call
    // costs nothing at all.
    public function PrePoint(UnivecContext $ctx): void
    {
        if (!$this->active) {
            return;
        }

        // Mark the context as running through the pipeline, so _charge knows a
        // PreDone is coming and does not commit the spend itself.
        if ($this->pending !== null) {
            $entry = isset($this->pending[$ctx]) ? $this->pending[$ctx] : $this->_newPending();
            $entry['piped'] = true;
            $this->pending[$ctx] = $entry;
        }

        $limit = $this->_limit();
        if ($limit <= 0.0) {
            return;
        }

        $client = $this->client;
        if ($client->_cost['total']['amount'] < $limit) {
            return;
        }

        $cost = $client->_cost;
        $cost['budget']['exceeded'] = true;
        $client->_cost = $cost;

        if (($this->options['onBudget'] ?? 'warn') !== 'deny') {
            return;
        }

        $err = $ctx->make_error('cost_budget',
            'Cost budget of ' . $this->_numstr($limit) . ' ' . $cost['currency'] .
            ' is spent (' . $this->_numstr((float)$cost['total']['amount']) . ' ' .
            $cost['currency'] . ' used)');

        // Short-circuit endpoint resolution; the pipeline surfaces this error.
        $ctx->out['point'] = $err;
    }

    private function _charge(UnivecContext $ctx, string $url, array $fetchdef, callable $inner): array
    {
        // A rejecting transport still costs an attempt. Without this, a run of
        // connection-level failures under `retry` (which catches and tries
        // again) would be charged nothing at all, and an onBudget 'deny'
        // ceiling could never stop it.
        $threw = null;
        try {
            [$res, $err] = $inner($ctx, $url, $fetchdef);
        } catch (\Throwable $ex) {
            $threw = $ex;
            $res = null;
            $err = $ex;
        }

        [$amount, $source] = $this->_price($ctx, $res);

        $entry = ($this->pending !== null && isset($this->pending[$ctx]))
            ? $this->pending[$ctx]
            : $this->_newPending();

        $entry['attempts']++;

        // Accumulated here, committed once at PreDone. Adding each attempt to
        // the running total and then subtracting it again when a body figure
        // supersedes it loses precision to catastrophic cancellation.
        //
        // Reported and estimated are kept apart per ATTEMPT: a 503 priced from
        // the rate table followed by a 200 carrying the cost header is part
        // estimate, part reported, and collapsing both into the final
        // attempt's category would corrupt the split.
        $entry['amount'] += $amount;
        $entry[('header' === $source || 'body' === $source) ? 'reported' : 'estimated'] += $amount;
        $entry['source'] = $source;

        if ($this->pending !== null) {
            $this->pending[$ctx] = $entry;
        }

        $client = $this->client;
        $cost = $client->_cost;
        $cost['total']['attempts']++;
        $client->_cost = $cost;

        // direct() and graphql() reach the transport without dispatching any
        // pipeline hooks, so there is no PrePoint to gate on and no PreDone to
        // commit. Their spend is committed here, or it would never be counted.
        // `piped` is set by PrePoint, so its absence is the signal.
        if (!$entry['piped']) {
            $this->_commit($ctx, $entry, '_', 'direct');
            if ($this->pending !== null) {
                unset($this->pending[$ctx]);
            }
        }

        if ($threw !== null) {
            throw $threw;
        }

        return [$res, $err];
    }

    private function _newPending(): array
    {
        return [
            'attempts' => 0, 'amount' => 0.0,
            'reported' => 0.0, 'estimated' => 0.0,
            'source' => 'none', 'piped' => false,
        ];
    }

    // Attribute the operation's spend once the call is finished.
    public function PreDone(UnivecContext $ctx): void
    {
        $this->_finish($ctx, true);
    }

    // A failed operation still spent the money. When the pipeline throws,
    // PreDone never runs, so without this the attempts are counted and the
    // spend is not, and a budget could never see the cost of a failed call.
    // Whichever hook fires first consumes the pending entry, so it commits
    // exactly once.
    public function PreUnexpected(UnivecContext $ctx): void
    {
        $this->_finish($ctx, false);
    }

    private function _finish(UnivecContext $ctx, bool $done): void
    {
        if (!$this->active || $this->pending === null || !isset($this->pending[$ctx])) {
            return;
        }
        $entry = $this->pending[$ctx];
        unset($this->pending[$ctx]);

        // A FAILED operation that made no attempt never reached the network:
        // PrePoint creates the pending entry to mark the context as piped, and
        // then the budget gate refuses the call (rbac, or an unresolvable
        // endpoint, short-circuits just as early). Committing it would count a
        // call that never happened and file a zero-amount record as `last`.
        //
        // A SUCCEEDED operation that made no attempt is the opposite case: it was
        // served from the cache. That is a real call, and the fact that it cost
        // nothing is the whole point of ordering cost inside the cache.
        if (!$done && 0 === $entry['attempts']) {
            return;
        }

        $entity = ($ctx->op !== null && $ctx->op->entity !== '') ? $ctx->op->entity : '_';
        $opname = ($ctx->op !== null && $ctx->op->name !== '') ? $ctx->op->name : '_';

        $this->_commit($ctx, $entry, $entity, $opname);
    }

    // Commit one operation's spend: totals, budget, per-op and per-actor
    // attribution, and the record. Shared by _finish and the raw-request path
    // in _charge, which has no PreDone to reach.
    private function _commit(UnivecContext $ctx, array $entry, string $entity, string $opname): void
    {
        $client = $this->client;
        $cost = $client->_cost;

        $amount = (float)$entry['amount'];
        $reported = (float)$entry['reported'];
        $estimated = (float)$entry['estimated'];
        $source = (string)$entry['source'];

        // A body figure prices the whole call, so it replaces the per-attempt
        // estimate rather than adding to it, and being server-stated the whole
        // amount counts as reported.
        $body = $this->_body($ctx);
        if ($body !== null) {
            $amount = $body;
            $reported = $body;
            $estimated = 0.0;
            $source = 'body';
        }

        $cost = $this->_spend($cost, $amount, $reported, $estimated);

        // ctrl->actor is an optional extension property on the control
        // object, same as the audit feature reads.
        $ctrl_actor = $ctx->ctrl->actor ?? null;
        $actor = (is_string($ctrl_actor) && $ctrl_actor !== '') ? $ctrl_actor
            : (string)($this->options['actor'] ?? 'anonymous');

        $cost['total']['calls']++;
        $cost['ops'] = $this->_bump($cost['ops'], $entity . '.' . $opname, $amount);
        $cost['actors'] = $this->_bump($cost['actors'], $actor, $amount);

        $this->seq++;
        $record = [
            'seq' => $this->seq,
            'entity' => $entity,
            'op' => $opname,
            'actor' => $actor,
            'amount' => $amount,
            'currency' => $cost['currency'],
            'source' => $source,
            'attempts' => $entry['attempts'],
        ];
        $cost['last'] = $record;
        $client->_cost = $cost;

        $sink = $this->options['sink'] ?? null;
        if (is_callable($sink)) {
            try {
                $sink($record);
            } catch (\Throwable $e) {
                // A failing sink must never take down the call.
            }
        }
    }

    // Price one attempt: a reported header figure, else the rate table, else
    // the flat unit.
    private function _price(UnivecContext $ctx, mixed $res): array
    {
        $header = $this->options['header'] ?? '';
        if (is_string($header) && '' !== $header) {
            $val = $this->_header($res, $header);
            if ($val !== null) {
                return [$val * $this->_perUnit(), 'header'];
            }
        }

        $rate = $this->_rate($ctx);
        if ($rate !== null) {
            return [$rate, 'table'];
        }

        $unit = $this->options['unit'] ?? 0;
        if (is_numeric($unit) && 0.0 !== (float)$unit) {
            return [(float)$unit, 'unit'];
        }

        return [0.0, 'none'];
    }

    // The rate table uses the same lookup grammar as rbac's rules:
    // `<entity>.<op>`, then `<op>`, then `*`.
    private function _rate(UnivecContext $ctx): ?float
    {
        $rates = $this->options['rates'] ?? null;
        if (!is_array($rates)) {
            return null;
        }

        $entity = '';
        if ($ctx->entity !== null && isset($ctx->entity->name)) {
            $entity = (string)$ctx->entity->name;
        } elseif ($ctx->op !== null) {
            $entity = $ctx->op->entity;
        }
        $opname = $ctx->op !== null ? $ctx->op->name : '';

        foreach ([$entity . '.' . $opname, $opname, '*'] as $key) {
            $val = $rates[$key] ?? null;
            if (is_numeric($val)) {
                return (float)$val;
            }
        }
        return null;
    }

    // A usage figure from the parsed result body, priced by perUnit. Read
    // here, not at the transport seam, because the body is one-shot.
    private function _body(UnivecContext $ctx): ?float
    {
        $path = $this->options['path'] ?? '';
        if (!is_string($path) || '' === $path) {
            return null;
        }
        if ($ctx->result === null || $ctx->result->body === null) {
            return null;
        }
        $val = \Voxgig\Struct\Struct::getpath($ctx->result->body, $path);
        if (!is_numeric($val)) {
            return null;
        }
        return (float)$val * $this->_perUnit();
    }

    private function _spend(array $cost, float $amount, float $reported, float $estimated): array
    {
        $cost['total']['amount'] += $amount;
        $cost['total']['reported'] += $reported;
        $cost['total']['estimated'] += $estimated;

        $limit = (float)$cost['budget']['limit'];
        $cost['budget']['spent'] = $cost['total']['amount'];
        if ($limit > 0.0) {
            $cost['budget']['remaining'] = max(0.0, $limit - (float)$cost['total']['amount']);
            if ((float)$cost['total']['amount'] >= $limit) {
                $cost['budget']['exceeded'] = true;
            }
        } else {
            $cost['budget']['remaining'] = 0.0;
        }
        return $cost;
    }

    private function _bump(array $bucket, string $key, float $amount): array
    {
        if (!isset($bucket[$key])) {
            $bucket[$key] = ['calls' => 0, 'amount' => 0.0];
        }
        $bucket[$key]['calls']++;
        $bucket[$key]['amount'] += $amount;
        return $bucket;
    }

    private function _header(mixed $res, string $name): ?float
    {
        if (!is_array($res)) {
            return null;
        }
        $headers = $res['headers'] ?? null;
        if (!is_array($headers)) {
            return null;
        }
        $lower = strtolower($name);
        foreach ($headers as $key => $val) {
            if (strtolower((string)$key) === $lower && is_numeric($val)) {
                return (float)$val;
            }
        }
        return null;
    }

    private function _perUnit(): float
    {
        $per = $this->options['perUnit'] ?? 0;
        return is_numeric($per) ? (float)$per : 0.0;
    }

    private function _limit(): float
    {
        $budget = $this->options['budget'] ?? 0;
        return is_numeric($budget) ? (float)$budget : 0.0;
    }

    // Render a money amount without an exponent or trailing zeros.
    private function _numstr(float $n): string
    {
        return rtrim(rtrim(number_format($n, 10, '.', ''), '0'), '.') ?: '0';
    }
}
