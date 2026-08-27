// Pagination support for list operations (mirrors feature/paging.rs). On the
// way out (PreRequest) it stamps page/limit (or a cursor) into the request
// query; on the way back (PreResult) it reads the server's pagination
// signals — a `Link: rel="next"` header, `X-Page`/`X-Next-Page`/
// `X-Total-Count` headers, or `next`/`cursor`/`nextCursor`/`hasMore` fields
// in the body — and records them on `result.paging`. A per-call cursor/page
// from ctrl takes priority (used by auto-iteration). Parameter names
// (`pageParam`, `limitParam`, `cursorParam`), the page size (`limit`) and
// the start page (`startPage`, default 1) are configurable.

#include "sdk.h"

#include <ctype.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;

  // Activity tracking (mirrors the ts client._paging record).
  voxgig_value* last;
} PagingFeature;

// True when opname is in the configured "ops" list (default ["list"]).
static bool is_list_op(voxgig_value* options, const char* opname) {
  voxgig_value* ops = fopt_list(options, "ops");
  if (voxgig_is_list(ops)) {
    voxgig_list* l = voxgig_as_list(ops);
    for (size_t i = 0; i < l->len; i++) {
      voxgig_value* v = l->items[i];
      if (voxgig_is_string(v) && strcmp(voxgig_as_string(v), opname) == 0) return true;
    }
    return false;
  }
  return strcmp(opname, "list") == 0;
}

// Extract the URL of the `rel="next"` entry from a Link header value. Returns
// a malloc'd string (caller frees) or NULL.
static char* link_next(const char* link) {
  const char* p = link;
  while (1) {
    const char* comma = strchr(p, ',');
    size_t seglen = comma ? (size_t)(comma - p) : strlen(p);

    // Lowercase copy of the segment for the rel="next" test.
    char* lower = (char*)malloc(seglen + 1);
    for (size_t i = 0; i < seglen; i++) lower[i] = (char)tolower((unsigned char)p[i]);
    lower[seglen] = '\0';
    bool match = strstr(lower, "rel=\"next\"") != NULL || strstr(lower, "rel=next") != NULL;
    free(lower);

    if (match) {
      // rust: seg.find('<')? and seg.find('>')? — absence returns None from
      // the whole function.
      const char* open = NULL;
      for (size_t i = 0; i < seglen; i++) {
        if (p[i] == '<') { open = &p[i]; break; }
      }
      if (!open) return NULL;
      const char* close = NULL;
      for (size_t i = 0; i < seglen; i++) {
        if (p[i] == '>') { close = &p[i]; break; }
      }
      if (!close) return NULL;
      if (open < close) {
        size_t len = (size_t)(close - open) - 1;
        char* out = (char*)malloc(len + 1);
        memcpy(out, open + 1, len);
        out[len] = '\0';
        return out;
      }
    }

    if (!comma) break;
    p = comma + 1;
  }
  return NULL;
}

static void header_num(voxgig_value* headers, const char* name, voxgig_value* paging,
                       const char* key) {
  voxgig_value* v = fheader_get(headers, name);
  if (v_is_noval(v)) return; // None
  if (voxgig_is_string(v)) {
    int64_t n = fparse_int(voxgig_as_string(v), -1);
    if (n >= 0) setp(paging, key, v_num((double)n));
  } else if (voxgig_is_number(v)) {
    double d = voxgig_is_int(v) ? (double)voxgig_as_int(v) : voxgig_as_double(v);
    setp(paging, key, v_num(d));
  }
}

static const char* paging_name(Feature* f) { return ((PagingFeature*)f)->name; }
static bool paging_active(Feature* f) { return ((PagingFeature*)f)->active; }
static voxgig_value* paging_add_options(Feature* f) { return ((PagingFeature*)f)->add_opts; }

static void paging_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  PagingFeature* pf = (PagingFeature*)f;
  pf->options = options;
  pf->active = fopt_bool(options, "active", false);
}

// The model records connection/cursor/more as dot paths; getpath_c takes a
// NULL-terminated segment array. Both the copy and the segment array are
// sized from the path itself: a fixed buffer would silently truncate a long
// generated path and look up the wrong node, which reads as "no cursor" and
// stops pagination after one page.
static voxgig_value* getpath_dotted(voxgig_value* store, const char* path) {
  if (!path || path[0] == '\0') return store;

  size_t len = strlen(path);

  // Segment count is bounded by dots + 1, so one allocation covers any path.
  size_t maxseg = 2;
  for (size_t i = 0; i < len; i++) {
    if (path[i] == '.') maxseg++;
  }

  char* buf = (char*)malloc(len + 1);
  const char** keys = (const char**)malloc(maxseg * sizeof(char*));
  if (!buf || !keys) {
    free(buf);
    free(keys);
    return voxgig_new_undef();
  }
  memcpy(buf, path, len + 1);

  size_t n = 0;
  char* save = NULL;
  for (char* tok = strtok_r(buf, ".", &save); tok;
       tok = strtok_r(NULL, ".", &save)) {
    keys[n++] = tok;
  }
  keys[n] = NULL;

  voxgig_value* out = getpath_c(store, keys);

  // getpath_c does not retain the key strings, so both buffers are ours to
  // release once the lookup has returned.
  free(buf);
  free(keys);

  return out;
}

// Relay pagination: the cursor is the `after` variable (or whatever the
// model named it), and the page size is `first`.
static void paging_graphql_pre_request(PagingFeature* pf, Context* ctx,
                                       voxgig_value* paging) {
  voxgig_value* options = pf->options;
  voxgig_value* body = ctx->spec->body;
  if (!voxgig_is_map(body)) return;

  voxgig_value* variables = getp(body, "variables");
  if (!voxgig_is_map(variables)) {
    variables = voxgig_new_map();
    setp(body, "variables", variables);
  }

  const char* after_var = fopt_str(options, "afterVar", "after");
  const char* first_var = fopt_str(options, "firstVar", "first");

  // Only bind variables the operation actually declares, or the server
  // rejects the document.
  bool after_declared = false, first_declared = false;
  voxgig_value* varlist = getpath2(ctx->point, "graphql", "vars");
  if (voxgig_is_list(varlist)) {
    voxgig_list* vl = voxgig_as_list(varlist);
    for (size_t i = 0; i < vl->len; i++) {
      voxgig_value* nv = getp(vl->items[i], "name");
      if (!voxgig_is_string(nv)) continue;
      const char* n = voxgig_as_string(nv);
      if (strcmp(n, after_var) == 0) after_declared = true;
      if (strcmp(n, first_var) == 0) first_declared = true;
    }
  }

  voxgig_value* cursor = getp(paging, "cursor");
  if (after_declared && !v_is_noval(cursor) && !v_is_null(cursor)) {
    setp(variables, after_var, v_share(cursor));
  }

  voxgig_value* limit = getp(options, "limit");
  if (first_declared && !v_is_noval(limit) && !v_is_null(limit) &&
      v_is_noval(getp(variables, first_var))) {
    setp(variables, first_var, v_num((double)fopt_int(options, "limit", 0)));
  }
}

static void paging_pre_request(PagingFeature* pf, Context* ctx) {
  voxgig_value* options = pf->options;
  if (!pf->active || !is_list_op(options, ctx->op->name)) return;
  if (!ctx->spec) return;

  voxgig_value* query = ctx->spec->query;
  if (!voxgig_is_map(query)) {
    query = voxgig_new_map();
    ctx->spec->query = query;
  }

  const char* page_param = fopt_str(options, "pageParam", "page");
  const char* limit_param = fopt_str(options, "limitParam", "limit");
  const char* cursor_param = fopt_str(options, "cursorParam", "cursor");

  // A per-call cursor/page from ctrl takes priority (auto-iteration).
  voxgig_value* paging = ctx->ctrl->paging;

  // GraphQL paginates through operation VARIABLES, not the query string.
  // This hook runs after make_spec, so spec->body already holds the
  // { query, variables } envelope, and before make_fetch_def serialises it.
  voxgig_value* kind = getp(ctx->point, "kind");
  if (voxgig_is_string(kind) && strcmp(voxgig_as_string(kind), "graphql") == 0) {
    paging_graphql_pre_request(pf, ctx, paging);
    return;
  }

  voxgig_value* cursor = getp(paging, "cursor");
  if (!v_is_noval(cursor) && !v_is_null(cursor)) {
    setp(query, cursor_param, cursor);
  } else if (v_is_noval(getp(query, page_param))) {
    voxgig_value* page = getp(paging, "page");
    if (!v_is_noval(page) && !v_is_null(page)) {
      setp(query, page_param, page);
    } else {
      setp(query, page_param, v_num((double)fopt_int(options, "startPage", 1)));
    }
  }

  if (!v_is_noval(getp(options, "limit")) && v_is_noval(getp(query, limit_param))) {
    setp(query, limit_param, v_num((double)fopt_int(options, "limit", 0)));
  }
}

static void paging_pre_result(PagingFeature* pf, Context* ctx) {
  voxgig_value* options = pf->options;
  if (!pf->active || !is_list_op(options, ctx->op->name)) return;
  if (!ctx->result) return;

  voxgig_value* headers = ctx->result->headers;
  voxgig_value* body = ctx->result->body;

  voxgig_value* paging = voxgig_new_map();
  setp(paging, "hasMore", v_bool(false));
  header_num(headers, "x-page", paging, "page");
  header_num(headers, "x-total-count", paging, "totalCount");
  header_num(headers, "x-next-page", paging, "nextPage");

  // Link: <...>; rel="next"
  voxgig_value* linkv = fheader_get(headers, "link");
  if (voxgig_is_string(linkv)) {
    char* next = link_next(voxgig_as_string(linkv));
    if (next) {
      setp(paging, "next", v_str(next));
      free(next);
    }
  }

  // Set when the response states hasMore outright, rather than leaving it to
  // be inferred from the presence of a cursor.
  bool explicit_more = false;

  // Relay connections carry the cursor in pageInfo, at the path the model
  // recorded for this op.
  voxgig_value* page = getpath2(ctx->point, "graphql", "page");
  if (voxgig_is_map(page) && voxgig_is_map(body)) {
    // `connpath` locates the connection object inside the response envelope
    // (data.<field>); the cursor/more paths are relative to it.
    voxgig_value* conn = body;
    voxgig_value* cpv = getp(page, "connpath");
    if (voxgig_is_string(cpv) && voxgig_as_string(cpv)[0] != '\0') {
      voxgig_value* sub = getpath_dotted(body, voxgig_as_string(cpv));
      if (!v_is_noval(sub) && !v_is_null(sub)) conn = sub;
    }

    voxgig_value* curv = getp(page, "cursor");
    if (voxgig_is_string(curv) && voxgig_as_string(curv)[0] != '\0') {
      voxgig_value* cursor = getpath_dotted(conn, voxgig_as_string(curv));
      if (!v_is_noval(cursor) && !v_is_null(cursor)) {
        setp(paging, "cursor", v_share(cursor));
      }
    }

    voxgig_value* morev = getp(page, "more");
    if (voxgig_is_string(morev) && voxgig_as_string(morev)[0] != '\0') {
      voxgig_value* mv = getpath_dotted(conn, voxgig_as_string(morev));
      if (voxgig_is_bool(mv)) {
        setp(paging, "hasMore", v_bool(voxgig_as_bool(mv)));
        explicit_more = true;
      }
    }
  }

  // Body-level cursors.
  if (voxgig_is_map(body)) {
    voxgig_value* next = getp(body, "next");
    if (!v_is_noval(next) && !v_is_null(next) && v_is_noval(getp(paging, "next"))) {
      setp(paging, "next", next);
    }
    voxgig_value* cursor = getp(body, "cursor");
    if (!v_is_noval(cursor) && !v_is_null(cursor)) {
      setp(paging, "cursor", cursor);
    }
    voxgig_value* next_cursor = getp(body, "nextCursor");
    if (!v_is_noval(next_cursor) && !v_is_null(next_cursor)) {
      setp(paging, "cursor", next_cursor);
    }
    bool has_more;
    if (get_bool(body, "hasMore", &has_more)) {
      setp(paging, "hasMore", v_bool(has_more));
      explicit_more = true;
    }
  }

  // Cursor presence only INFERS another page. When the server stated the
  // answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
  // that wins: a final page normally carries both an end cursor and
  // hasNextPage false, and inferring from the cursor there would send the
  // caller back for a page that does not exist, forever.
  bool hm = false;
  bool has = get_bool(paging, "hasMore", &hm);
  bool is_true = has && hm;
  if (!explicit_more && !is_true &&
      (!v_is_noval(getp(paging, "next")) || !v_is_noval(getp(paging, "cursor")) ||
       !v_is_noval(getp(paging, "nextPage")))) {
    setp(paging, "hasMore", v_bool(true));
  }

  ctx->result->paging = paging;
  pf->last = paging;
}

static void paging_hook(Feature* f, const char* name, Context* ctx) {
  PagingFeature* pf = (PagingFeature*)f;
  if (strcmp(name, "PreRequest") == 0) {
    paging_pre_request(pf, ctx);
  } else if (strcmp(name, "PreResult") == 0) {
    paging_pre_result(pf, ctx);
  }
}

static const FeatureVT PAGING_VT = {
  paging_name, paging_active, paging_add_options, paging_init, paging_hook,
  NULL, // paging state observed via result.paging, not a track snapshot
};

Feature* feature_paging_new(void) {
  PagingFeature* pf = (PagingFeature*)calloc(1, sizeof(PagingFeature));
  pf->base.vt = &PAGING_VT;
  pf->name = strdup("paging");
  pf->active = true; // matches rust new() (overridden by init from options)
  pf->add_opts = NULL;
  pf->options = voxgig_new_undef();
  pf->last = voxgig_new_undef();
  return (Feature*)pf;
}
