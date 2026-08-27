# Univec SDK paging feature

from __future__ import annotations
import re

from univec_sdk.utility.voxgig_struct import voxgig_struct as vs

from univec_sdk.feature.base_feature import UnivecBaseFeature


# Pagination support for list operations. On the way out (PreRequest) it
# stamps page/limit (or a cursor) into the request query; on the way back
# (PreResult) it reads the server's pagination signals — a `Link:
# rel="next"` header, `X-Page`/`X-Next-Page`/`X-Total-Count` headers, or
# `next`/`cursor`/`nextCursor`/`hasMore` fields in the body — and records
# them on `ctx.result.paging`. A per-call cursor/page supplied via ctrl
# paging takes priority (used by auto-iteration). Parameter names
# (`pageParam`/`limitParam`/`cursorParam`), `startPage` and page size
# (`limit`) are configurable.
class UnivecPagingFeature(UnivecBaseFeature):
    def __init__(self):
        super().__init__()
        self.version = "0.0.1"
        self.name = "paging"
        self.active = True
        self.client = None
        self.options = {}

    def init(self, ctx, options):
        self.client = ctx.client
        self.options = options if isinstance(options, dict) else {}

        if self.options.get("active") is True:
            self.active = True
        else:
            self.active = False

    def PreRequest(self, ctx):
        if not self.active:
            return
        if not self._is_list(ctx):
            return
        spec = ctx.spec
        if spec is None:
            return
        if spec.query is None:
            spec.query = {}

        page_param = self.options.get("pageParam") or "page"
        limit_param = self.options.get("limitParam") or "limit"
        cursor_param = self.options.get("cursorParam") or "cursor"

        # A per-call cursor/page from ctrl takes priority (auto-iteration).
        paging = getattr(ctx.ctrl, "paging", None) if ctx.ctrl is not None else None
        if not isinstance(paging, dict):
            paging = {}

        # GraphQL paginates through operation VARIABLES, not the query
        # string. This hook runs after make_spec, so spec.body already holds
        # the { query, variables } envelope, and before make_fetch_def
        # serialises it.
        if "graphql" == vs.getprop(ctx.point, "kind"):
            self._graphql_pre_request(ctx, paging)
            return

        if paging.get("cursor") is not None:
            spec.query[cursor_param] = paging["cursor"]
        elif spec.query.get(page_param) is None:
            page = paging.get("page")
            if page is None:
                page = self.options.get("startPage") or 1
            spec.query[page_param] = page

        if self.options.get("limit") is not None and spec.query.get(limit_param) is None:
            spec.query[limit_param] = self.options.get("limit")

    # Relay pagination: the cursor is the `after` variable (or whatever the
    # model named it), and the page size is `first`.
    def _graphql_pre_request(self, ctx, paging):
        body = ctx.spec.body
        if not isinstance(body, dict):
            return

        variables = body.get("variables")
        if not isinstance(variables, dict):
            variables = {}
            body["variables"] = variables

        after_var = self.options.get("afterVar") or "after"
        first_var = self.options.get("firstVar") or "first"

        # Only bind variables the operation actually declares, or the server
        # rejects the document.
        declared = set()
        varlist = vs.getpath(ctx.point, "graphql.vars")
        if isinstance(varlist, list):
            for v in varlist:
                name = vs.getprop(v, "name")
                if name is not None:
                    declared.add(name)

        if paging.get("cursor") is not None and after_var in declared:
            variables[after_var] = paging["cursor"]

        limit = self.options.get("limit")
        if (limit is not None and variables.get(first_var) is None
                and first_var in declared):
            variables[first_var] = limit

    def PreResult(self, ctx):
        if not self.active:
            return
        if not self._is_list(ctx):
            return
        result = ctx.result
        if result is None:
            return

        headers = result.headers or {}
        body = result.body

        paging = {
            "page": self._num(self._header(headers, "x-page")),
            "totalCount": self._num(self._header(headers, "x-total-count")),
            "nextPage": self._num(self._header(headers, "x-next-page")),
            "next": None,
            "cursor": None,
            "hasMore": False,
        }

        # Link: <...>; rel="next"
        link = self._header(headers, "link")
        if link is not None:
            m = re.search(r'<([^>]+)>\s*;\s*rel="?next"?', str(link), re.IGNORECASE)
            if m:
                paging["next"] = m.group(1)

        # Set when the response states hasMore outright, rather than leaving
        # it to be inferred from the presence of a cursor.
        explicit_more = False

        # Relay connections carry the cursor in pageInfo, at the path the
        # model recorded for this op.
        page = vs.getpath(ctx.point, "graphql.page")
        if isinstance(page, dict) and isinstance(body, dict):
            # `connpath` locates the connection object inside the response
            # envelope (data.<field>); the cursor/more paths are relative
            # to it.
            connpath = page.get("connpath")
            conn = body
            if isinstance(connpath, str) and "" != connpath:
                sub = vs.getpath(body, connpath)
                if sub is not None:
                    conn = sub

            cursorpath = page.get("cursor")
            if isinstance(cursorpath, str) and "" != cursorpath:
                cursor = vs.getpath(conn, cursorpath)
                if cursor is not None:
                    paging["cursor"] = cursor

            morepath = page.get("more")
            if isinstance(morepath, str) and "" != morepath:
                more = vs.getpath(conn, morepath)
                if isinstance(more, bool):
                    paging["hasMore"] = more
                    explicit_more = True

        # Body-level cursors.
        if isinstance(body, dict):
            if body.get("next") is not None:
                paging["next"] = paging["next"] or body["next"]
            if body.get("cursor") is not None:
                paging["cursor"] = body["cursor"]
            if body.get("nextCursor") is not None:
                paging["cursor"] = body["nextCursor"]
            if isinstance(body.get("hasMore"), bool):
                paging["hasMore"] = body["hasMore"]
                explicit_more = True

        # Cursor presence only INFERS another page. When the server stated
        # the answer outright — relay's `hasNextPage: false`, or a body
        # `hasMore` — that wins: a final page normally carries both an end
        # cursor and hasNextPage false, and inferring from the cursor there
        # would send the caller back for a page that does not exist, forever.
        if not explicit_more:
            paging["hasMore"] = (paging["hasMore"]
                                 or paging["next"] is not None
                                 or paging["cursor"] is not None
                                 or paging["nextPage"] is not None)

        result.paging = paging

        self.client._paging = {"last": paging}

    def _is_list(self, ctx):
        ops = self.options.get("ops") or ["list"]
        opname = ctx.op.name if ctx.op is not None else None
        return opname in ops

    def _header(self, headers, name):
        lower = name.lower()
        for key in headers:
            if str(key).lower() == lower:
                return headers[key]
        return None

    def _num(self, val):
        if val is None:
            return None
        try:
            n = float(val)
        except (TypeError, ValueError):
            return None
        return int(n) if n.is_integer() else n
