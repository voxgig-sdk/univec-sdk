"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.PagingFeature = void 0;
const BaseFeature_1 = require("../base/BaseFeature");
// Pagination support for list operations. On the way out (PreRequest) it
// stamps page/limit (or a cursor) into the request query; on the way back
// (PreResult) it reads the server's pagination signals — a `Link:
// rel="next"` header, `X-Next-Page`/`X-Total-Count` headers, or `next`/
// `cursor`/`hasMore` fields in the body — and records them on
// `ctx.result.paging`. Generated SDKs build auto-iteration on top of this
// (advance the cursor/page and re-issue the list call until `hasMore` is
// false). Parameter names and page size are configurable.
class PagingFeature extends BaseFeature_1.BaseFeature {
    version = '0.0.1';
    name = 'paging';
    active = true;
    _client;
    _options = {};
    init(ctx, options) {
        this._client = ctx.client;
        this._options = options || {};
        this.active = options.active;
    }
    PreRequest(ctx) {
        if (!this._isList(ctx)) {
            return;
        }
        const spec = ctx.spec;
        if (null == spec) {
            return;
        }
        if (null == spec.query) {
            spec.query = {};
        }
        const pageParam = this._options.pageParam || 'page';
        const limitParam = this._options.limitParam || 'limit';
        const cursorParam = this._options.cursorParam || 'cursor';
        // A per-call cursor/page from ctrl takes priority (used by auto-iteration).
        const paging = (ctx.ctrl && ctx.ctrl.paging) || {};
        // GraphQL paginates through operation VARIABLES, not the query string.
        // This hook runs after makeSpec, so spec.body already holds the
        // { query, variables } envelope, and before makeFetchDef serialises it.
        const point = ctx.point;
        if ('graphql' === (null == point ? undefined : point.kind)) {
            return this._graphqlPreRequest(ctx, paging);
        }
        if (null != paging.cursor) {
            spec.query[cursorParam] = paging.cursor;
        }
        else if (null == spec.query[pageParam]) {
            spec.query[pageParam] = null != paging.page ? paging.page : (this._options.startPage || 1);
        }
        if (null != this._options.limit && null == spec.query[limitParam]) {
            spec.query[limitParam] = this._options.limit;
        }
    }
    PreResult(ctx) {
        if (!this._isList(ctx)) {
            return;
        }
        const result = ctx.result;
        if (null == result) {
            return;
        }
        const headers = result.headers || {};
        const body = result.body;
        // Set when the response states hasMore outright, rather than leaving it
        // to be inferred from the presence of a cursor.
        let explicitMore = false;
        const paging = {
            page: this._num(this._header(headers, 'x-page')),
            totalCount: this._num(this._header(headers, 'x-total-count')),
            nextPage: this._num(this._header(headers, 'x-next-page')),
            next: undefined,
            cursor: undefined,
            hasMore: false,
        };
        // Link: <...>; rel="next"
        const link = this._header(headers, 'link');
        if (null != link) {
            const m = /<([^>]+)>\s*;\s*rel="?next"?/i.exec(link);
            if (m) {
                paging.next = m[1];
            }
        }
        // Relay connections carry the cursor in pageInfo, at the path the model
        // recorded for this op.
        const point = ctx.point;
        const page = null == point ? undefined : (point.graphql || {}).page;
        if (null != page && body && 'object' === typeof body) {
            const struct = ctx.utility.struct;
            // `connpath` locates the connection object inside the response
            // envelope (data.<field>); the cursor/more paths are relative to it.
            const conn = null == page.connpath || '' === page.connpath ? body :
                (struct.getpath(body, page.connpath) || body);
            const cursor = struct.getpath(conn, page.cursor);
            const more = struct.getpath(conn, page.more);
            if (null != cursor) {
                paging.cursor = cursor;
            }
            if ('boolean' === typeof more) {
                paging.hasMore = more;
                explicitMore = true;
            }
        }
        // Body-level cursors.
        if (body && 'object' === typeof body) {
            if (null != body.next) {
                paging.next = paging.next || body.next;
            }
            if (null != body.cursor) {
                paging.cursor = body.cursor;
            }
            if (null != body.nextCursor) {
                paging.cursor = body.nextCursor;
            }
            if ('boolean' === typeof body.hasMore) {
                paging.hasMore = body.hasMore;
                explicitMore = true;
            }
        }
        // Cursor presence only INFERS another page. When the server stated the
        // answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
        // that wins: a final page normally carries both an end cursor and
        // hasNextPage false, and inferring from the cursor there would send the
        // caller back for a page that does not exist, forever.
        if (!explicitMore) {
            paging.hasMore = paging.hasMore ||
                null != paging.next || null != paging.cursor || null != paging.nextPage;
        }
        result.paging = paging;
        const client = this._client;
        client._paging = { last: paging };
    }
    // Relay pagination: the cursor is the `after` variable (or whatever the
    // model recorded), and the page size the `first` variable.
    _graphqlPreRequest(ctx, paging) {
        const spec = ctx.spec;
        const point = ctx.point;
        const body = spec.body;
        if (null == body || 'object' !== typeof body) {
            return;
        }
        const vars = (body.variables = body.variables || {});
        const afterVar = this._options.afterVar || 'after';
        const firstVar = this._options.firstVar || 'first';
        // Only bind variables the operation actually declares, or the server
        // rejects the document.
        const declared = {};
        for (const v of ((point.graphql && point.graphql.vars) || [])) {
            declared[v.name] = true;
        }
        if (null != paging.cursor && declared[afterVar]) {
            vars[afterVar] = paging.cursor;
        }
        if (null != this._options.limit && null == vars[firstVar] &&
            declared[firstVar]) {
            vars[firstVar] = this._options.limit;
        }
    }
    _isList(ctx) {
        const ops = this._options.ops || ['list'];
        return ops.indexOf(ctx.op && ctx.op.name) >= 0;
    }
    _header(headers, name) {
        const lower = name.toLowerCase();
        for (const k of Object.keys(headers)) {
            if (k.toLowerCase() === lower) {
                return headers[k];
            }
        }
        return undefined;
    }
    _num(v) {
        if (null == v) {
            return undefined;
        }
        const n = Number(v);
        return isNaN(n) ? undefined : n;
    }
}
exports.PagingFeature = PagingFeature;
//# sourceMappingURL=PagingFeature.js.map