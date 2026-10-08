<?php
declare(strict_types=1);

// Univec SDK debug feature

require_once __DIR__ . '/BaseFeature.php';

// Request/response capture for debugging. Records a bounded ring buffer of
// per-operation traces — method, URL, redacted headers, response status and
// timing — on `client->_debug['entries']`. The SDK's own clean rules apply
// to the whole entry, and header names in `redact` are masked on top of
// them. An optional `onEntry` callback receives each finished entry (e.g.
// to stream to a console). `max` caps the buffer (default 100). Mirrors
// ts/src/feature/debug/DebugFeature.ts.
class UnivecDebugFeature extends UnivecBaseFeature
{
    private mixed $client;
    private ?array $options;
    private ?\WeakMap $entries;

    public function __construct()
    {
        parent::__construct();
        $this->version = '0.0.1';
        $this->name = 'debug';
        $this->active = true;
        $this->client = null;
        $this->options = null;
        $this->entries = null;
    }

    public function init(UnivecContext $ctx, array $options): void
    {
        $this->client = $ctx->client;
        $this->options = $options;
        $this->active = ($options['active'] ?? null) === true;
        $this->entries = new \WeakMap();

        if (!$this->active) {
            return;
        }

        $client = $this->client;
        if (!isset($client->_debug)) {
            $client->_debug = ['entries' => []];
        }
    }

    public function PreRequest(UnivecContext $ctx): void
    {
        if (!$this->active || $this->entries === null) {
            return;
        }
        $spec = $ctx->spec;
        $entry = [
            'op' => ($ctx->op->entity !== '' ? $ctx->op->entity : '_')
                . '.' . ($ctx->op->name !== '' ? $ctx->op->name : '_'),
            'method' => $spec !== null ? $spec->method : null,
            'url' => $spec !== null ? ($spec->url !== '' ? $spec->url : $spec->path) : null,
            'headers' => $this->_redact($ctx, $spec !== null ? $spec->headers : null),
            'start' => $this->_now(),
            'status' => null,
            'ok' => null,
            'durationMs' => null,
            'error' => null,
        ];
        $this->entries[$ctx] = $entry;
    }

    public function PreResponse(UnivecContext $ctx): void
    {
        if (!$this->active || $this->entries === null || !isset($this->entries[$ctx])) {
            return;
        }
        $entry = $this->entries[$ctx];
        $response = $ctx->response;
        if ($response !== null) {
            $entry['status'] = $response->status;
            if (($entry['url'] === null || $entry['url'] === '') && $ctx->spec !== null) {
                $entry['url'] = $ctx->spec->url;
            }
            // PHP arrays are value types: write the updated entry back.
            $this->entries[$ctx] = $entry;
        }
    }

    public function PreDone(UnivecContext $ctx): void
    {
        if (!$this->active) {
            return;
        }
        $this->_finish($ctx, true);
    }

    public function PreUnexpected(UnivecContext $ctx): void
    {
        if (!$this->active) {
            return;
        }
        if ($this->entries !== null && isset($this->entries[$ctx])) {
            $entry = $this->entries[$ctx];
            $err = $ctx->ctrl->err;
            $entry['error'] = ($err instanceof \Throwable) ? $err->getMessage() : null;
            $this->entries[$ctx] = $entry;
        }
        $this->_finish($ctx, false);
    }

    private function _finish(UnivecContext $ctx, bool $ok): void
    {
        // Finish once per operation: a PreDone followed by an unexpected
        // failure finds no open entry and no-ops.
        if ($this->entries === null || !isset($this->entries[$ctx])) {
            return;
        }
        $entry = $this->entries[$ctx];
        unset($this->entries[$ctx]);

        $entry['ok'] = $ok && ($ctx->result === null || $ctx->result->ok !== false);
        $entry['durationMs'] = max(0.0, $this->_now() - (float)$entry['start']);
        if ($entry['status'] === null && $ctx->result !== null) {
            $entry['status'] = $ctx->result->status;
        }

        // The whole entry leaves through the buffer and the callback: the url
        // and the error message can carry a query credential the header mask
        // above never saw.
        $entry = ($ctx->utility->clean)($ctx, $entry);

        $client = $this->client;
        $client->_debug['entries'][] = $entry;
        $max = is_numeric($this->options['max'] ?? null) ? (int)$this->options['max'] : 100;
        while (count($client->_debug['entries']) > $max) {
            array_shift($client->_debug['entries']);
        }

        $on_entry = $this->options['onEntry'] ?? null;
        if (is_callable($on_entry)) {
            try {
                $on_entry($entry);
            } catch (\Throwable $_e) {
                // Callback failures must never break the pipeline.
            }
        }
    }

    // The core clean rules apply (clean.keys, every registered value); the
    // feature's own `redact` list ADDS header names on top of them.
    private function _redact(UnivecContext $ctx, mixed $headers): array
    {
        if (!is_array($headers)) {
            return [];
        }
        $patterns = $this->options['redact'] ?? [];
        if (!is_array($patterns)) {
            $patterns = [];
        }
        $patterns = array_map(function (mixed $n): string {
            return strtolower((string)$n);
        }, $patterns);
        $out = [];
        foreach ($headers as $k => $v) {
            $out[$k] = in_array(strtolower((string)$k), $patterns, true) ? '[redacted]' : $v;
        }
        return ($ctx->utility->clean)($ctx, $out);
    }

    private function _now(): float
    {
        $now = $this->options['now'] ?? null;
        if (is_callable($now)) {
            return (float)$now();
        }
        return microtime(true) * 1000.0;
    }
}
