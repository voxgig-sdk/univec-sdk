package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Result
import KOTLINPACKAGE.utility.struct.Struct

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

// Content type every GraphQL-over-HTTP request uses.
const val GRAPHQL_CONTENT_TYPE = "application/json"

// Map a GraphQL error to the same error codes the HTTP path produces, so a
// caller handles auth or rate limiting identically on both transports.
// Servers put the machine-readable code in `extensions.code`; Linear-style
// APIs use `extensions.type`.
fun graphqlErrorCode(gqlerr: Any?): String {
  val ext = Struct.getprop(gqlerr, "extensions")

  var code = Struct.getprop(ext, "code") as? String
  if (code.isNullOrEmpty()) {
    code = Struct.getprop(ext, "type") as? String
  }
  val raw = (code ?: "").uppercase()

  if (raw.contains("AUTH") || raw.contains("FORBIDDEN") ||
    raw.contains("UNAUTHENTICATED")
  ) {
    return "request_auth"
  }
  if (raw.contains("RATELIMIT") || raw.contains("RATE_LIMIT") ||
    raw.contains("TOO_MANY")
  ) {
    return "request_ratelimit"
  }
  if (raw.contains("BAD_USER_INPUT") || raw.contains("VALIDATION") ||
    raw.contains("INVALID")
  ) {
    return "request_invalid"
  }

  return "request_graphql"
}

// Build the request body for a GraphQL point.
//
// Variables come from the op's own arguments: a named variable binds to the
// like-named argument (`from`), and the input-object variable (empty
// `from`) takes the request data as a whole — which is what makes a
// generated create/update call look exactly like its REST equivalent.
@Suppress("UNCHECKED_CAST")
fun graphqlBody(ctx: Context): Any? {
  val gql = Struct.getprop(ctx.point, "graphql") as? Map<String, Any?>
    ?: return null

  // reqmatch/reqdata hold the caller's arguments for THIS call; data/match
  // hold the entity's current state. Which pair depends on whether the op
  // takes match or data input. A named variable falls back to the current
  // state, so updating a loaded entity with just {title} still binds the
  // stored id the mutation requires.
  val datainput = null != ctx.op && "data" == ctx.op!!.input
  val src = (if (datainput) ctx.reqdata else ctx.reqmatch) ?: mutableMapOf()
  val statesrc = (if (datainput) ctx.data else ctx.match) ?: mutableMapOf()

  val variables = mutableMapOf<String, Any?>()

  val varlist = Struct.getprop(gql, "vars") as? List<Any?> ?: emptyList()

  for (entry in varlist) {
    val spec = entry as? Map<String, Any?> ?: continue

    val name = Struct.getprop(spec, "name") as? String ?: continue
    val from = Struct.getprop(spec, "from") as? String

    if (from.isNullOrEmpty()) {
      // The input object IS the request body. Strip the action selector,
      // which is an SDK-side point discriminator, not an API field.
      val body = mutableMapOf<String, Any?>()
      for ((k, v) in src) {
        if ("\$action" != k) {
          body[k] = v
        }
      }
      variables[name] = body
      continue
    }

    // Only send variables the caller actually supplied: sending an explicit
    // null would clear a field on many APIs.
    val value = Struct.getprop(src, from) ?: Struct.getprop(statesrc, from)
    if (null != value) {
      variables[name] = value
    }
  }

  return mutableMapOf<String, Any?>(
    "query" to Struct.getprop(gql, "doc"),
    "variables" to variables,
  )
}

// Inspect a decoded GraphQL response body and record a failure when the
// server reported one. Returns true when an error was recorded.
//
// Partial data (`data` alongside `errors`) is treated as failure: the REST
// surface has no partial-success concept, and silently returning half an
// object would be worse than failing.
fun graphqlErrors(ctx: Context): Boolean {
  val result = ctx.result ?: return false
  if (null == ctx.point) return false

  if ("graphql" != Struct.getprop(ctx.point, "kind") as? String) {
    return false
  }

  val errors = Struct.getprop(result.body, "errors") as? List<Any?>
    ?: return false
  if (errors.isEmpty()) return false

  val first = errors[0]
  var msg = Struct.getprop(first, "message") as? String
  if (msg.isNullOrEmpty()) {
    msg = "graphql error"
  }
  if (1 < errors.size) {
    msg = msg + " (+" + (errors.size - 1) + " more)"
  }

  result.err = ctx.makeError(graphqlErrorCode(first), "graphql: " + msg)
  result.ok = false

  return true
}
