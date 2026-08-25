import Foundation

// GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
// produces uses this file unchanged. The API-specific part — which
// operations exist and what each one's document is — is model data,
// computed once by apidef and emitted into Config.
//
// Two jobs:
//
//   graphqlBodyUtil   — build { query, variables } for a point, binding the
//                       op's arguments to the document's declared variables.
//
//   graphqlErrorsUtil — lift a GraphQL failure into an SDK error. GraphQL
//                       reports failures as a top-level `errors` array under
//                       HTTP 200, so the status-driven path in resultBasic
//                       never sees them.

/// Content type every GraphQL-over-HTTP request uses.
let graphqlContentType = "application/json"

/// Map a GraphQL error to the same error codes the HTTP path produces, so a
/// caller handles auth or rate limiting identically on both transports.
/// Servers put the machine-readable code in `extensions.code`; Linear-style
/// APIs use `extensions.type`.
func graphqlErrorCode(_ gqlerr: Value) -> String {
  let ext = gp(gqlerr, "extensions")

  var code = gp(ext, "code").asString ?? ""
  if code.isEmpty {
    code = gp(ext, "type").asString ?? ""
  }
  let raw = code.uppercased()

  if raw.contains("AUTH") || raw.contains("FORBIDDEN")
    || raw.contains("UNAUTHENTICATED") {
    return "request_auth"
  }
  if raw.contains("RATELIMIT") || raw.contains("RATE_LIMIT")
    || raw.contains("TOO_MANY") {
    return "request_ratelimit"
  }
  if raw.contains("BAD_USER_INPUT") || raw.contains("VALIDATION")
    || raw.contains("INVALID") {
    return "request_invalid"
  }

  return "request_graphql"
}

/// Build the request body for a GraphQL point.
///
/// Variables come from the op's own arguments: a named variable binds to the
/// like-named argument (`from`), and the input-object variable (empty
/// `from`) takes the request data as a whole — which is what makes a
/// generated create/update call look exactly like its REST equivalent.
func graphqlBodyUtil(_ ctx: Context) -> Value {
  let gql = gp(ctx.point, "graphql")
  guard nil != gql.asMap else { return .noval }

  // reqmatch/reqdata hold the caller's arguments for THIS call; data/match
  // hold the entity's current state. Which pair depends on whether the op
  // takes match or data input. A named variable falls back to the current
  // state, so updating a loaded entity with just {title} still binds the
  // stored id the mutation requires.
  var reqsrc = ctx.reqmatch
  var datasrc = ctx.match
  if let op = ctx.op, "data" == op.input {
    reqsrc = ctx.reqdata
    datasrc = ctx.data
  }

  let variables = VMap()

  if let varlist = gp(gql, "vars").asList {
    for spec in varlist.items {
      guard nil != spec.asMap else { continue }

      let name = gp(spec, "name").asString ?? ""
      if name.isEmpty { continue }

      let from = gp(spec, "from").asString ?? ""

      if from.isEmpty {
        // The input object IS the request body. Strip the action selector,
        // which is an SDK-side point discriminator, not an API field.
        let body = VMap()
        for item in items(.map(reqsrc)) {
          let key = item[0].asString ?? ""
          if "$action" != key {
            body.entries[key] = item[1]
          }
        }
        variables.entries[name] = .map(body)
        continue
      }

      // Only send variables the caller actually supplied: sending an
      // explicit null would clear a field on many APIs.
      var val = gp(.map(reqsrc), from)
      if isNil(val) {
        val = gp(.map(datasrc), from)
      }
      if !isNil(val) {
        variables.entries[name] = val
      }
    }
  }

  let out = VMap()
  out.entries["query"] = gp(gql, "doc")
  out.entries["variables"] = .map(variables)

  return .map(out)
}

/// Inspect a decoded GraphQL response body and record a failure when the
/// server reported one. Returns true when an error was recorded.
///
/// Partial data (`data` alongside `errors`) is treated as failure: the REST
/// surface has no partial-success concept, and silently returning half an
/// object would be worse than failing.
@discardableResult
func graphqlErrorsUtil(_ ctx: Context) -> Bool {
  guard let result = ctx.result else { return false }

  guard "graphql" == gp(ctx.point, "kind").asString else { return false }

  guard let errors = gp(result.body, "errors").asList else { return false }
  if errors.items.isEmpty { return false }

  let first = errors.items[0]
  var msg = gp(first, "message").asString ?? ""
  if msg.isEmpty { msg = "graphql error" }
  if 1 < errors.items.count {
    msg = msg + " (+\(errors.items.count - 1) more)"
  }

  result.err = ctx.makeError(graphqlErrorCode(first), "graphql: " + msg)
  result.ok = false

  return true
}
