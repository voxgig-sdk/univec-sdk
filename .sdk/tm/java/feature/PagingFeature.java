package JAVAPACKAGE.feature;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.utility.struct.Struct;

// Pagination support for list operations. On the way out (PreRequest) it
// stamps page/limit (or a cursor) into the request query; on the way back
// (PreResult) it reads the server's pagination signals — a `Link:
// rel="next"` header, `X-Page`/`X-Next-Page`/`X-Total-Count` headers, or
// `next`/`cursor`/`nextCursor`/`hasMore` fields in the body — and records
// them on `ctx.result.paging`. A per-call cursor/page from ctrl takes
// priority (used by auto-iteration). Parameter names (`pageParam`,
// `limitParam`, `cursorParam`), the page size (`limit`) and the start page
// (`startPage`, default 1) are configurable.
@SuppressWarnings({"unchecked"})
public class PagingFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;

  // Activity tracking (mirrors the ts client._paging record).
  public Map<String, Object> last;

  private static final Pattern LINK_NEXT_RE =
      Pattern.compile("<([^>]+)>\\s*;\\s*rel=\"?next\"?", Pattern.CASE_INSENSITIVE);

  public PagingFeature() {
    super("paging", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);
  }

  @Override
  public void preRequest(Context ctx) {
    if (!this.active || !isList(ctx)) {
      return;
    }
    Spec spec = ctx.spec;
    if (spec == null) {
      return;
    }
    if (spec.query == null) {
      spec.query = new LinkedHashMap<>();
    }

    String pageParam = FeatureOptions.foptStr(this.options, "pageParam", "page");
    String limitParam = FeatureOptions.foptStr(this.options, "limitParam", "limit");
    String cursorParam = FeatureOptions.foptStr(this.options, "cursorParam", "cursor");

    // A per-call cursor/page from ctrl takes priority (auto-iteration).
    Map<String, Object> paging = ctx.ctrl == null ? null : ctx.ctrl.paging;
    if (paging == null) {
      paging = new LinkedHashMap<>();
    }

    // GraphQL paginates through operation VARIABLES, not the query string.
    // This hook runs after makeSpec, so spec.body already holds the
    // { query, variables } envelope, and before makeFetchDef serialises it.
    if ("graphql".equals(Struct.getprop(ctx.point, "kind", null))) {
      graphqlPreRequest(ctx, paging);
      return;
    }

    Object cursor = paging.get("cursor");
    if (cursor != null) {
      spec.query.put(cursorParam, cursor);
    }
    else if (spec.query.get(pageParam) == null) {
      Object page = paging.get("page");
      if (page != null) {
        spec.query.put(pageParam, page);
      }
      else {
        spec.query.put(pageParam, FeatureOptions.foptInt(this.options, "startPage", 1));
      }
    }

    if (this.options.get("limit") != null && spec.query.get(limitParam) == null) {
      spec.query.put(limitParam, FeatureOptions.foptInt(this.options, "limit", 0));
    }
  }

  // Relay pagination: the cursor is the `after` variable (or whatever the
  // model named it), and the page size is `first`.
  @SuppressWarnings("unchecked")
  private void graphqlPreRequest(Context ctx, Map<String, Object> paging) {
    if (!(ctx.spec.body instanceof Map)) {
      return;
    }
    Map<String, Object> body = (Map<String, Object>) ctx.spec.body;

    Object varsval = body.get("variables");
    Map<String, Object> variables;
    if (varsval instanceof Map) {
      variables = (Map<String, Object>) varsval;
    }
    else {
      variables = new LinkedHashMap<>();
      body.put("variables", variables);
    }

    String afterVar = FeatureOptions.foptStr(this.options, "afterVar", "after");
    String firstVar = FeatureOptions.foptStr(this.options, "firstVar", "first");

    // Only bind variables the operation actually declares, or the server
    // rejects the document.
    Set<String> declared = new LinkedHashSet<>();
    Object varlist = Struct.getpath(ctx.point, List.of("graphql", "vars"));
    if (varlist instanceof List) {
      for (Object v : (List<Object>) varlist) {
        Object name = Struct.getprop(v, "name", null);
        if (name instanceof String) {
          declared.add((String) name);
        }
      }
    }

    if (paging.get("cursor") != null && declared.contains(afterVar)) {
      variables.put(afterVar, paging.get("cursor"));
    }

    if (this.options.get("limit") != null && variables.get(firstVar) == null
        && declared.contains(firstVar)) {
      variables.put(firstVar, FeatureOptions.foptInt(this.options, "limit", 0));
    }
  }

  @Override
  public void preResult(Context ctx) {
    if (!this.active || !isList(ctx)) {
      return;
    }
    Result result = ctx.result;
    if (result == null) {
      return;
    }

    Map<String, Object> headers = result.headers;
    Object body = result.body;

    Map<String, Object> paging = new LinkedHashMap<>();
    paging.put("hasMore", false);
    headerNum(headers, "x-page", paging, "page");
    headerNum(headers, "x-total-count", paging, "totalCount");
    headerNum(headers, "x-next-page", paging, "nextPage");

    // Link: <...>; rel="next"
    Object link = FeatureOptions.fheaderGet(headers, "link");
    if (link instanceof String) {
      Matcher m = LINK_NEXT_RE.matcher((String) link);
      if (m.find()) {
        paging.put("next", m.group(1));
      }
    }

    // Set when the response states hasMore outright, rather than leaving it
    // to be inferred from the presence of a cursor.
    boolean explicitMore = false;

    // Relay connections carry the cursor in pageInfo, at the path the model
    // recorded for this op.
    Object page = Struct.getpath(ctx.point, List.of("graphql", "page"));
    if (page instanceof Map && body instanceof Map) {
      // `connpath` locates the connection object inside the response
      // envelope (data.<field>); the cursor/more paths are relative to it.
      Object connpath = Struct.getprop(page, "connpath", null);
      Object conn = body;
      if (connpath instanceof String && !"".equals(connpath)) {
        Object sub = Struct.getpath(body, connpath);
        if (sub != null) {
          conn = sub;
        }
      }

      Object cursorpath = Struct.getprop(page, "cursor", null);
      if (cursorpath instanceof String && !"".equals(cursorpath)) {
        Object cursor = Struct.getpath(conn, cursorpath);
        if (cursor != null) {
          paging.put("cursor", cursor);
        }
      }

      Object morepath = Struct.getprop(page, "more", null);
      if (morepath instanceof String && !"".equals(morepath)) {
        Object more = Struct.getpath(conn, morepath);
        if (more instanceof Boolean) {
          paging.put("hasMore", more);
          explicitMore = true;
        }
      }
    }

    // Body-level cursors.
    if (body instanceof Map) {
      Map<String, Object> bm = (Map<String, Object>) body;
      if (bm.get("next") != null && paging.get("next") == null) {
        paging.put("next", bm.get("next"));
      }
      if (bm.get("cursor") != null) {
        paging.put("cursor", bm.get("cursor"));
      }
      if (bm.get("nextCursor") != null) {
        paging.put("cursor", bm.get("nextCursor"));
      }
      if (bm.get("hasMore") instanceof Boolean) {
        paging.put("hasMore", bm.get("hasMore"));
        explicitMore = true;
      }
    }

    // Cursor presence only INFERS another page. When the server stated the
    // answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
    // that wins: a final page normally carries both an end cursor and
    // hasNextPage false, and inferring from the cursor there would send the
    // caller back for a page that does not exist, forever.
    if (!explicitMore && !Boolean.TRUE.equals(paging.get("hasMore"))
        && (paging.get("next") != null || paging.get("cursor") != null
            || paging.get("nextPage") != null)) {
      paging.put("hasMore", true);
    }

    result.paging = paging;
    this.last = paging;
  }

  private boolean isList(Context ctx) {
    String opname = "";
    if (ctx.op != null) {
      opname = ctx.op.name;
    }
    List<String> ops = FeatureOptions.foptStrList(this.options, "ops");
    if (ops == null) {
      ops = List.of("list");
    }
    for (String o : ops) {
      if (o.equals(opname)) {
        return true;
      }
    }
    return false;
  }

  private void headerNum(Map<String, Object> headers, String name,
      Map<String, Object> paging, String key) {

    Object v = FeatureOptions.fheaderGet(headers, name);
    if (v == null) {
      return;
    }
    if (v instanceof String) {
      int n = FeatureOptions.fparseInt((String) v, -1);
      if (n >= 0) {
        paging.put(key, n);
      }
      return;
    }
    if (v instanceof Number) {
      paging.put(key, ((Number) v).intValue());
    }
  }
}
