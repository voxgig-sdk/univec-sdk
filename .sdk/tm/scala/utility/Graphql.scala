package SCALAPACKAGE.utility

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import SCALAPACKAGE.core._
import SCALAPACKAGE.utility.struct.Struct

// GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
// produces uses this file unchanged. The API-specific part — which
// operations exist and what each one's document is — is model data,
// computed once by apidef and emitted into Config.
//
// Two jobs:
//
//   graphqlBody   — build { query, variables } for a point, binding the
//                   op's arguments to the document's declared variables.
//
//   graphqlErrors — lift a GraphQL failure into an SDK error. GraphQL
//                   reports failures as a top-level `errors` array under
//                   HTTP 200, so the status-driven path in resultBasic
//                   never sees them.
object Graphql {

  // Content type every GraphQL-over-HTTP request uses.
  val ContentType: String = "application/json"

  // Map a GraphQL error to the same error codes the HTTP path produces, so
  // a caller handles auth or rate limiting identically on both transports.
  // Servers put the machine-readable code in `extensions.code`;
  // Linear-style APIs use `extensions.type`.
  def errorCode(gqlerr: Object): String = {
    val ext = Struct.getprop(gqlerr, "extensions")

    var code = Struct.getprop(ext, "code") match {
      case s: String => s
      case _ => ""
    }
    if (code == null || code.isEmpty) {
      code = Struct.getprop(ext, "type") match {
        case s: String => s
        case _ => ""
      }
    }
    val raw = code.toUpperCase

    if (raw.contains("AUTH") || raw.contains("FORBIDDEN") ||
        raw.contains("UNAUTHENTICATED")) return "request_auth"
    if (raw.contains("RATELIMIT") || raw.contains("RATE_LIMIT") ||
        raw.contains("TOO_MANY")) return "request_ratelimit"
    if (raw.contains("BAD_USER_INPUT") || raw.contains("VALIDATION") ||
        raw.contains("INVALID")) return "request_invalid"

    "request_graphql"
  }

  // Build the request body for a GraphQL point.
  //
  // Variables come from the op's own arguments: a named variable binds to
  // the like-named argument (`from`), and the input-object variable (empty
  // `from`) takes the request data as a whole — which is what makes a
  // generated create/update call look exactly like its REST equivalent.
  def graphqlBody(ctx: Context): Object = {
    val gql = Helpers.toMapAny(Struct.getprop(ctx.point, "graphql"))
    if (gql == null) return null

    // reqmatch/reqdata hold the caller's arguments for THIS call; data/match
    // hold the entity's current state. Which pair depends on whether the op
    // takes match or data input. A named variable falls back to the current
    // state, so updating a loaded entity with just {title} still binds the
    // stored id the mutation requires.
    val datainput = ctx.op != null && "data" == ctx.op.input
    var reqsrc = if (datainput) ctx.reqdata else ctx.reqmatch
    var datasrc = if (datainput) ctx.data else ctx.matchData
    if (reqsrc == null) reqsrc = new LinkedHashMap[String, Object]()
    if (datasrc == null) datasrc = new LinkedHashMap[String, Object]()

    val variables = new LinkedHashMap[String, Object]()

    val varlist = Struct.getprop(gql, "vars") match {
      case l: JList[_] => l.asInstanceOf[JList[Object]]
      case _ => new ArrayList[Object]()
    }

    val it = varlist.iterator()
    while (it.hasNext) {
      val spec = Helpers.toMapAny(it.next())
      if (spec != null) {
        val name = Struct.getprop(spec, "name") match {
          case s: String => s
          case _ => null
        }
        val from = Struct.getprop(spec, "from") match {
          case s: String => s
          case _ => ""
        }

        if (name != null) {
          if (from == null || from.isEmpty) {
            // The input object IS the request body. Strip the action
            // selector, which is an SDK-side point discriminator, not an
            // API field.
            val body = new LinkedHashMap[String, Object]()
            val ks = reqsrc.keySet().iterator()
            while (ks.hasNext) {
              val k = ks.next()
              if ("$action" != k) body.put(k, reqsrc.get(k))
            }
            variables.put(name, body)
          } else {
            // Only send variables the caller actually supplied: sending an
            // explicit null would clear a field on many APIs.
            var v = Struct.getprop(reqsrc, from)
            if (v == null) v = Struct.getprop(datasrc, from)
            if (v != null) variables.put(name, v)
          }
        }
      }
    }

    val out = new LinkedHashMap[String, Object]()
    out.put("query", Struct.getprop(gql, "doc"))
    out.put("variables", variables)
    out
  }

  // Inspect a decoded GraphQL response body and record a failure when the
  // server reported one. Returns true when an error was recorded.
  //
  // Partial data (`data` alongside `errors`) is treated as failure: the
  // REST surface has no partial-success concept, and silently returning
  // half an object would be worse than failing.
  def graphqlErrors(ctx: Context): java.lang.Boolean = {
    val result = ctx.result
    if (result == null || ctx.point == null) return false

    val kind = Struct.getprop(ctx.point, "kind") match {
      case s: String => s
      case _ => ""
    }
    if ("graphql" != kind) return false

    val errors = Struct.getprop(result.body, "errors") match {
      case l: JList[_] => l.asInstanceOf[JList[Object]]
      case _ => null
    }
    if (errors == null || errors.isEmpty) return false

    val first = errors.get(0)
    var msg = Struct.getprop(first, "message") match {
      case s: String => s
      case _ => ""
    }
    if (msg == null || msg.isEmpty) msg = "graphql error"
    if (1 < errors.size) msg = msg + " (+" + (errors.size - 1) + " more)"

    result.err = ctx.makeError(errorCode(first), "graphql: " + msg)
    result.ok = false

    true
  }
}
