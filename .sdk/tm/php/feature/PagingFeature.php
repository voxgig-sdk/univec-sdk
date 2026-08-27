<?php
declare(strict_types=1);

// Univec SDK paging feature

require_once __DIR__ . '/BaseFeature.php';

// Pagination support for list operations. On the way out (PreRequest) it
// stamps page/limit (or a cursor) into the request query; on the way back
// (PreResult) it reads the server's pagination signals — a `Link:
// rel="next"` header, `X-Page`/`X-Next-Page`/`X-Total-Count` headers, or
// `next`/`cursor`/`nextCursor`/`hasMore` fields in the body — and records
// them on `$ctx->result->paging`. A per-call `ctrl->paging` (page or
// cursor) takes priority over the stamped defaults; parameter names and
// page size are configurable; `startPage` defaults to 1. Mirrors
// ts/src/feature/paging/PagingFeature.ts.
class UnivecPagingFeature extends UnivecBaseFeature
{
    private mixed $client;
    private ?array $options;

    public function __construct()
    {
        parent::__construct();
        $this->version = '0.0.1';
        $this->name = 'paging';
        $this->active = true;
        $this->client = null;
        $this->options = null;
    }

    public function init(UnivecContext $ctx, array $options): void
    {
        $this->client = $ctx->client;
        $this->options = $options;
        $this->active = ($options['active'] ?? null) === true;
    }

    public function PreRequest(UnivecContext $ctx): void
    {
        if (!$this->active || !$this->_is_list($ctx)) {
            return;
        }
        $spec = $ctx->spec;
        if ($spec === null) {
            return;
        }

        $page_param = $this->options['pageParam'] ?? 'page';
        $limit_param = $this->options['limitParam'] ?? 'limit';
        $cursor_param = $this->options['cursorParam'] ?? 'cursor';

        // A per-call cursor/page from ctrl takes priority (used by
        // auto-iteration). ctrl->paging is an optional extension property.
        $paging = $ctx->ctrl->paging ?? null;
        if (!is_array($paging)) {
            $paging = [];
        }

        // GraphQL paginates through operation VARIABLES, not the query
        // string. This hook runs after makeSpec, so spec->body already holds
        // the { query, variables } envelope, and before makeFetchDef
        // serialises it.
        if ('graphql' === \Voxgig\Struct\Struct::getprop($ctx->point, 'kind')) {
            $this->_graphql_pre_request($ctx, $paging);
            return;
        }

        if (($paging['cursor'] ?? null) !== null) {
            $spec->query[$cursor_param] = $paging['cursor'];
        } elseif (($spec->query[$page_param] ?? null) === null) {
            $start_page = is_numeric($this->options['startPage'] ?? null)
                ? $this->options['startPage'] : 1;
            $spec->query[$page_param] = ($paging['page'] ?? null) !== null
                ? $paging['page'] : $start_page;
        }

        if (($this->options['limit'] ?? null) !== null
            && ($spec->query[$limit_param] ?? null) === null) {
            $spec->query[$limit_param] = $this->options['limit'];
        }
    }

    // Relay pagination: the cursor is the `after` variable (or whatever the
    // model named it), and the page size is `first`.
    private function _graphql_pre_request(UnivecContext $ctx, array $paging): void
    {
        $body = $ctx->spec->body;
        if (!is_array($body)) {
            return;
        }

        $variables = $body['variables'] ?? null;
        if (!is_array($variables)) {
            $variables = [];
        }

        $after_var = $this->options['afterVar'] ?? 'after';
        $first_var = $this->options['firstVar'] ?? 'first';

        // Only bind variables the operation actually declares, or the server
        // rejects the document.
        $declared = [];
        $varlist = \Voxgig\Struct\Struct::getpath($ctx->point, 'graphql.vars');
        if (is_array($varlist)) {
            foreach ($varlist as $v) {
                $name = \Voxgig\Struct\Struct::getprop($v, 'name');
                if (null !== $name) {
                    $declared[$name] = true;
                }
            }
        }

        if (($paging['cursor'] ?? null) !== null
            && ($declared[$after_var] ?? false)) {
            $variables[$after_var] = $paging['cursor'];
        }

        if (($this->options['limit'] ?? null) !== null
            && ($variables[$first_var] ?? null) === null
            && ($declared[$first_var] ?? false)) {
            $variables[$first_var] = $this->options['limit'];
        }

        // PHP arrays are values, not references: write the whole envelope
        // back or the bindings are lost.
        $body['variables'] = $variables;
        $ctx->spec->body = $body;
    }

    public function PreResult(UnivecContext $ctx): void
    {
        if (!$this->active || !$this->_is_list($ctx)) {
            return;
        }
        $result = $ctx->result;
        if ($result === null) {
            return;
        }

        $headers = is_array($result->headers) ? $result->headers : [];
        $body = $result->body;

        $paging = [
            'page' => $this->_num($this->_header($headers, 'x-page')),
            'totalCount' => $this->_num($this->_header($headers, 'x-total-count')),
            'nextPage' => $this->_num($this->_header($headers, 'x-next-page')),
            'next' => null,
            'cursor' => null,
            'hasMore' => false,
        ];

        // Link: <...>; rel="next"
        $link = $this->_header($headers, 'link');
        if (is_string($link) && preg_match('/<([^>]+)>\s*;\s*rel="?next"?/i', $link, $m)) {
            $paging['next'] = $m[1];
        }

        // Set when the response states hasMore outright, rather than leaving
        // it to be inferred from the presence of a cursor.
        $explicit_more = false;

        // Relay connections carry the cursor in pageInfo, at the path the
        // model recorded for this op.
        $page = \Voxgig\Struct\Struct::getpath($ctx->point, 'graphql.page');
        if (is_array($page) && is_array($body)) {
            // `connpath` locates the connection object inside the response
            // envelope (data.<field>); the cursor/more paths are relative
            // to it.
            $connpath = $page['connpath'] ?? null;
            $conn = $body;
            if (is_string($connpath) && '' !== $connpath) {
                $sub = \Voxgig\Struct\Struct::getpath($body, $connpath);
                if (null !== $sub) {
                    $conn = $sub;
                }
            }

            $cursorpath = $page['cursor'] ?? null;
            if (is_string($cursorpath) && '' !== $cursorpath) {
                $cursor = \Voxgig\Struct\Struct::getpath($conn, $cursorpath);
                if (null !== $cursor) {
                    $paging['cursor'] = $cursor;
                }
            }

            $morepath = $page['more'] ?? null;
            if (is_string($morepath) && '' !== $morepath) {
                $more = \Voxgig\Struct\Struct::getpath($conn, $morepath);
                if (is_bool($more)) {
                    $paging['hasMore'] = $more;
                    $explicit_more = true;
                }
            }
        }

        // Body-level cursors.
        if (is_array($body)) {
            if (($body['next'] ?? null) !== null) {
                $paging['next'] = $paging['next'] ?? $body['next'];
            }
            if (($body['cursor'] ?? null) !== null) {
                $paging['cursor'] = $body['cursor'];
            }
            if (($body['nextCursor'] ?? null) !== null) {
                $paging['cursor'] = $body['nextCursor'];
            }
            if (is_bool($body['hasMore'] ?? null)) {
                $paging['hasMore'] = $body['hasMore'];
                $explicit_more = true;
            }
        }

        // Cursor presence only INFERS another page. When the server stated
        // the answer outright — relay's `hasNextPage: false`, or a body
        // `hasMore` — that wins: a final page normally carries both an end
        // cursor and hasNextPage false, and inferring from the cursor there
        // would send the caller back for a page that does not exist, forever.
        if (!$explicit_more) {
            $paging['hasMore'] = $paging['hasMore']
                || $paging['next'] !== null
                || $paging['cursor'] !== null
                || $paging['nextPage'] !== null;
        }

        $result->paging = $paging;

        $this->client->_paging = ['last' => $paging];
    }

    private function _is_list(UnivecContext $ctx): bool
    {
        $ops = $this->options['ops'] ?? ['list'];
        return is_array($ops) && in_array($ctx->op->name, $ops, true);
    }

    private function _header(array $headers, string $name): mixed
    {
        $lower = strtolower($name);
        foreach ($headers as $k => $v) {
            if (is_string($k) && strtolower($k) === $lower) {
                return $v;
            }
        }
        return null;
    }

    private function _num(mixed $v): mixed
    {
        if ($v === null || !is_numeric($v)) {
            return null;
        }
        return $v + 0;
    }
}
