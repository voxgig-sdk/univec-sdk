package SCALAPACKAGE.feature

import java.util.{LinkedHashMap, List => JList, Map => JMap}
import java.util.regex.{Matcher, Pattern}
import SCALAPACKAGE.core.{Context, SdkClient}
import SCALAPACKAGE.utility.struct.Struct

// Pagination support for list operations. On the way out (PreRequest) it
// stamps page/limit (or a cursor) into the request query; on the way back
// (PreResult) it reads the server's pagination signals — a `Link:
// rel="next"` header, `X-Page`/`X-Next-Page`/`X-Total-Count` headers, or
// `next`/`cursor`/`nextCursor`/`hasMore` fields in the body — and records
// them on `ctx.result.paging`. A per-call cursor/page from ctrl takes
// priority (used by auto-iteration). Parameter names (`pageParam`,
// `limitParam`, `cursorParam`), the page size (`limit`) and the start page
// (`startPage`, default 1) are configurable.
class PagingFeature extends BaseFeature("paging", "0.0.1", true) {

  private var client: SdkClient = null
  private var options: JMap[String, Object] = null

  // Activity tracking (mirrors the ts client._paging record).
  var last: JMap[String, Object] = null

  private val LINK_NEXT_RE: Pattern =
    Pattern.compile("<([^>]+)>\\s*;\\s*rel=\"?next\"?", Pattern.CASE_INSENSITIVE)

  override def init(ctx: Context, options: JMap[String, Object]): Unit = {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
  }

  override def preRequest(ctx: Context): Unit = {
    if (!this.active || !isList(ctx)) {
      return
    }
    val spec = ctx.spec
    if (spec == null) {
      return
    }
    if (spec.query == null) {
      spec.query = new LinkedHashMap[String, Object]()
    }

    val pageParam = FeatureOptions.foptStr(this.options, "pageParam", "page")
    val limitParam = FeatureOptions.foptStr(this.options, "limitParam", "limit")
    val cursorParam = FeatureOptions.foptStr(this.options, "cursorParam", "cursor")

    // A per-call cursor/page from ctrl takes priority (auto-iteration).
    var paging: JMap[String, Object] = if (ctx.ctrl == null) null else ctx.ctrl.paging
    if (paging == null) {
      paging = new LinkedHashMap[String, Object]()
    }

    // GraphQL paginates through operation VARIABLES, not the query string.
    // This hook runs after makeSpec, so spec.body already holds the
    // { query, variables } envelope, and before makeFetchDef serialises it.
    if ("graphql" == Struct.getprop(ctx.point, "kind")) {
      graphqlPreRequest(ctx, paging)
      return
    }

    val cursor = paging.get("cursor")
    if (cursor != null) {
      spec.query.put(cursorParam, cursor)
    } else if (spec.query.get(pageParam) == null) {
      val page = paging.get("page")
      if (page != null) {
        spec.query.put(pageParam, page)
      } else {
        spec.query.put(pageParam, java.lang.Integer.valueOf(FeatureOptions.foptInt(this.options, "startPage", 1)))
      }
    }

    if (this.options.get("limit") != null && spec.query.get(limitParam) == null) {
      spec.query.put(limitParam, java.lang.Integer.valueOf(FeatureOptions.foptInt(this.options, "limit", 0)))
    }
  }

  // Relay pagination: the cursor is the `after` variable (or whatever the
  // model named it), and the page size is `first`.
  private def graphqlPreRequest(ctx: Context, paging: JMap[String, Object]): Unit = {
    val body = ctx.spec.body match {
      case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
      case _ => return
    }

    val variables = body.get("variables") match {
      case m: JMap[_, _] => m.asInstanceOf[JMap[String, Object]]
      case _ =>
        val nv = new LinkedHashMap[String, Object]()
        body.put("variables", nv)
        nv
    }

    val afterVar = FeatureOptions.foptStr(this.options, "afterVar", "after")
    val firstVar = FeatureOptions.foptStr(this.options, "firstVar", "first")

    // Only bind variables the operation actually declares, or the server
    // rejects the document.
    val declared = new java.util.HashSet[String]()
    Struct.getpath(ctx.point, java.util.List.of("graphql", "vars")) match {
      case vl: JList[_] =>
        val it = vl.iterator()
        while (it.hasNext) {
          Struct.getprop(it.next(), "name") match {
            case n: String => declared.add(n)
            case _ =>
          }
        }
      case _ =>
    }

    val cursor = paging.get("cursor")
    if (cursor != null && declared.contains(afterVar)) {
      variables.put(afterVar, cursor)
    }

    if (this.options.get("limit") != null && variables.get(firstVar) == null &&
      declared.contains(firstVar)) {
      variables.put(firstVar,
        java.lang.Integer.valueOf(FeatureOptions.foptInt(this.options, "limit", 0)))
    }
  }

  override def preResult(ctx: Context): Unit = {
    if (!this.active || !isList(ctx)) {
      return
    }
    val result = ctx.result
    if (result == null) {
      return
    }

    val headers = result.headers
    val body = result.body

    val paging = new LinkedHashMap[String, Object]()
    paging.put("hasMore", java.lang.Boolean.FALSE)
    headerNum(headers, "x-page", paging, "page")
    headerNum(headers, "x-total-count", paging, "totalCount")
    headerNum(headers, "x-next-page", paging, "nextPage")

    // Link: <...>; rel="next"
    val link = FeatureOptions.fheaderGet(headers, "link")
    link match {
      case s: String =>
        val m = LINK_NEXT_RE.matcher(s)
        if (m.find()) {
          paging.put("next", m.group(1))
        }
      case _ =>
    }

    // Set when the response states hasMore outright, rather than leaving it
    // to be inferred from the presence of a cursor.
    var explicitMore = false

    // Relay connections carry the cursor in pageInfo, at the path the model
    // recorded for this op.
    (Struct.getpath(ctx.point, java.util.List.of("graphql", "page")), body) match {
      case (pg: JMap[_, _], _: JMap[_, _]) =>
        val page = pg.asInstanceOf[JMap[String, Object]]
        // `connpath` locates the connection object inside the response
        // envelope (data.<field>); the cursor/more paths are relative to it.
        var conn: Object = body
        page.get("connpath") match {
          case cp: String if cp.nonEmpty =>
            val sub = Struct.getpath(body, cp)
            if (sub != null) conn = sub
          case _ =>
        }

        page.get("cursor") match {
          case cur: String if cur.nonEmpty =>
            val c = Struct.getpath(conn, cur)
            if (c != null) paging.put("cursor", c)
          case _ =>
        }

        page.get("more") match {
          case mp: String if mp.nonEmpty =>
            Struct.getpath(conn, mp) match {
              case b: java.lang.Boolean =>
                paging.put("hasMore", b)
                explicitMore = true
              case _ =>
            }
          case _ =>
        }
      case _ =>
    }

    // Body-level cursors.
    body match {
      case bm0: JMap[_, _] =>
        val bm = bm0.asInstanceOf[JMap[String, Object]]
        if (bm.get("next") != null && paging.get("next") == null) {
          paging.put("next", bm.get("next"))
        }
        if (bm.get("cursor") != null) {
          paging.put("cursor", bm.get("cursor"))
        }
        if (bm.get("nextCursor") != null) {
          paging.put("cursor", bm.get("nextCursor"))
        }
        bm.get("hasMore") match {
          case b: java.lang.Boolean =>
            paging.put("hasMore", b)
            explicitMore = true
          case _ =>
        }
      case _ =>
    }

    // Cursor presence only INFERS another page. When the server stated the
    // answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
    // that wins: a final page normally carries both an end cursor and
    // hasNextPage false, and inferring from the cursor there would send the
    // caller back for a page that does not exist, forever.
    if (!explicitMore && !(java.lang.Boolean.TRUE == paging.get("hasMore"))
        && (paging.get("next") != null || paging.get("cursor") != null
            || paging.get("nextPage") != null)) {
      paging.put("hasMore", java.lang.Boolean.TRUE)
    }

    result.paging = paging
    this.last = paging
  }

  private def isList(ctx: Context): Boolean = {
    var opname = ""
    if (ctx.op != null) {
      opname = ctx.op.name
    }
    var ops = FeatureOptions.foptStrList(this.options, "ops")
    if (ops == null) {
      ops = java.util.List.of("list")
    }
    val it = ops.iterator()
    while (it.hasNext) {
      if (it.next().equals(opname)) {
        return true
      }
    }
    false
  }

  private def headerNum(headers: JMap[String, Object], name: String,
      paging: JMap[String, Object], key: String): Unit = {

    val v = FeatureOptions.fheaderGet(headers, name)
    if (v == null) {
      return
    }
    v match {
      case s: String =>
        val n = FeatureOptions.fparseInt(s, -1)
        if (n >= 0) {
          paging.put(key, java.lang.Integer.valueOf(n))
        }
        return
      case _ =>
    }
    v match {
      case num: java.lang.Number => paging.put(key, java.lang.Integer.valueOf(num.intValue()))
      case _ =>
    }
  }
}
