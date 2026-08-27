package KOTLINPACKAGE.feature

import java.util.regex.Pattern

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.SdkClient
import KOTLINPACKAGE.utility.struct.Struct

// Pagination support for list operations. On the way out (PreRequest) it
// stamps page/limit (or a cursor) into the request query; on the way back
// (PreResult) it reads the server's pagination signals and records them on
// `ctx.result.paging`.
@Suppress("UNCHECKED_CAST")
class PagingFeature : BaseFeature("paging", "0.0.1", true) {

  private var client: SdkClient? = null
  private var options: MutableMap<String, Any?>? = null

  // Activity tracking (mirrors the ts client._paging record).
  var last: MutableMap<String, Any?>? = null

  override fun init(ctx: Context, options: MutableMap<String, Any?>) {
    this.client = ctx.client
    this.options = options
    this.active = FeatureOptions.foptBool(options, "active", false)
  }

  override fun preRequest(ctx: Context) {
    if (!this.active || !isList(ctx)) {
      return
    }
    val spec = ctx.spec ?: return

    val pageParam = FeatureOptions.foptStr(this.options, "pageParam", "page")
    val limitParam = FeatureOptions.foptStr(this.options, "limitParam", "limit")
    val cursorParam = FeatureOptions.foptStr(this.options, "cursorParam", "cursor")

    // A per-call cursor/page from ctrl takes priority (auto-iteration).
    var paging = ctx.ctrl.paging
    if (paging == null) {
      paging = linkedMapOf()
    }

    // GraphQL paginates through operation VARIABLES, not the query string.
    // This hook runs after makeSpec, so spec.body already holds the
    // { query, variables } envelope, and before makeFetchDef serialises it.
    if ("graphql" == Struct.getprop(ctx.point, "kind") as? String) {
      graphqlPreRequest(ctx, paging)
      return
    }

    val cursor = paging["cursor"]
    if (cursor != null) {
      spec.query[cursorParam] = cursor
    } else if (spec.query[pageParam] == null) {
      val page = paging["page"]
      if (page != null) {
        spec.query[pageParam] = page
      } else {
        spec.query[pageParam] = FeatureOptions.foptInt(this.options, "startPage", 1)
      }
    }

    if (this.options?.get("limit") != null && spec.query[limitParam] == null) {
      spec.query[limitParam] = FeatureOptions.foptInt(this.options, "limit", 0)
    }
  }

  // Relay pagination: the cursor is the `after` variable (or whatever the
  // model named it), and the page size is `first`.
  private fun graphqlPreRequest(ctx: Context, paging: MutableMap<String, Any?>) {
    val body = ctx.spec?.body as? MutableMap<String, Any?> ?: return

    var variables = body["variables"] as? MutableMap<String, Any?>
    if (variables == null) {
      variables = linkedMapOf()
      body["variables"] = variables
    }

    val afterVar = FeatureOptions.foptStr(this.options, "afterVar", "after")
    val firstVar = FeatureOptions.foptStr(this.options, "firstVar", "first")

    // Only bind variables the operation actually declares, or the server
    // rejects the document.
    val declared = mutableSetOf<String>()
    val varlist = Struct.getpath(ctx.point, listOf("graphql", "vars")) as? List<Any?>
    if (varlist != null) {
      for (v in varlist) {
        val name = Struct.getprop(v, "name") as? String
        if (name != null) {
          declared.add(name)
        }
      }
    }

    val cursor = paging["cursor"]
    if (cursor != null && declared.contains(afterVar)) {
      variables[afterVar] = cursor
    }

    if (this.options?.get("limit") != null && variables[firstVar] == null &&
      declared.contains(firstVar)
    ) {
      variables[firstVar] = FeatureOptions.foptInt(this.options, "limit", 0)
    }
  }

  override fun preResult(ctx: Context) {
    if (!this.active || !isList(ctx)) {
      return
    }
    val result = ctx.result ?: return

    val headers = result.headers
    val body = result.body

    val paging = linkedMapOf<String, Any?>()
    paging["hasMore"] = false
    headerNum(headers, "x-page", paging, "page")
    headerNum(headers, "x-total-count", paging, "totalCount")
    headerNum(headers, "x-next-page", paging, "nextPage")

    // Link: <...>; rel="next"
    val link = FeatureOptions.fheaderGet(headers, "link")
    if (link is String) {
      val mm = LINK_NEXT_RE.matcher(link)
      if (mm.find()) {
        paging["next"] = mm.group(1)
      }
    }

    // Set when the response states hasMore outright, rather than leaving it
    // to be inferred from the presence of a cursor.
    var explicitMore = false

    // Relay connections carry the cursor in pageInfo, at the path the model
    // recorded for this op.
    val page = Struct.getpath(ctx.point, listOf("graphql", "page")) as? Map<*, *>
    if (page != null && body is MutableMap<*, *>) {
      // `connpath` locates the connection object inside the response
      // envelope (data.<field>); the cursor/more paths are relative to it.
      var conn: Any? = body
      val connpath = page["connpath"] as? String
      if (!connpath.isNullOrEmpty()) {
        val sub = Struct.getpath(body, connpath)
        if (sub != null) {
          conn = sub
        }
      }

      val cursorpath = page["cursor"] as? String
      if (!cursorpath.isNullOrEmpty()) {
        val c = Struct.getpath(conn, cursorpath)
        if (c != null) {
          paging["cursor"] = c
        }
      }

      val morepath = page["more"] as? String
      if (!morepath.isNullOrEmpty()) {
        val more = Struct.getpath(conn, morepath)
        if (more is Boolean) {
          paging["hasMore"] = more
          explicitMore = true
        }
      }
    }

    // Body-level cursors.
    if (body is MutableMap<*, *>) {
      val bm = body as MutableMap<String, Any?>
      if (bm["next"] != null && paging["next"] == null) {
        paging["next"] = bm["next"]
      }
      if (bm["cursor"] != null) {
        paging["cursor"] = bm["cursor"]
      }
      if (bm["nextCursor"] != null) {
        paging["cursor"] = bm["nextCursor"]
      }
      if (bm["hasMore"] is Boolean) {
        paging["hasMore"] = bm["hasMore"]
        explicitMore = true
      }
    }

    // Cursor presence only INFERS another page. When the server stated the
    // answer outright — relay's `hasNextPage: false`, or a body `hasMore` —
    // that wins: a final page normally carries both an end cursor and
    // hasNextPage false, and inferring from the cursor there would send the
    // caller back for a page that does not exist, forever.
    if (!explicitMore && paging["hasMore"] != true &&
      (paging["next"] != null || paging["cursor"] != null || paging["nextPage"] != null)
    ) {
      paging["hasMore"] = true
    }

    result.paging = paging
    this.last = paging
  }

  private fun isList(ctx: Context): Boolean {
    val opname = ctx.op.name
    var ops: List<String>? = FeatureOptions.foptStrList(this.options, "ops")
    if (ops == null) {
      ops = listOf("list")
    }
    for (o in ops) {
      if (o == opname) {
        return true
      }
    }
    return false
  }

  private fun headerNum(headers: MutableMap<String, Any?>, name: String, paging: MutableMap<String, Any?>, key: String) {
    val v = FeatureOptions.fheaderGet(headers, name) ?: return
    if (v is String) {
      val n = FeatureOptions.fparseInt(v, -1)
      if (n >= 0) {
        paging[key] = n
      }
      return
    }
    if (v is Number) {
      paging[key] = v.toInt()
    }
  }

  companion object {
    private val LINK_NEXT_RE: Pattern =
      Pattern.compile("<([^>]+)>\\s*;\\s*rel=\"?next\"?", Pattern.CASE_INSENSITIVE)
  }
}
