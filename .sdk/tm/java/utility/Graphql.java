package JAVAPACKAGE.utility;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Result;
import JAVAPACKAGE.utility.struct.Struct;

/**
 * GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
 * produces uses this file unchanged. The API-specific part — which
 * operations exist and what each one's document is — is model data,
 * computed once by apidef and emitted into Config.
 *
 * <p>Two jobs:
 *
 * <p>graphqlBody — build { query, variables } for a point, binding the op's
 * arguments to the document's declared variables.
 *
 * <p>graphqlErrors — lift a GraphQL failure into an SDK error. GraphQL
 * reports failures as a top-level {@code errors} array under HTTP 200, so
 * the status-driven path in resultBasic never sees them.
 */
@SuppressWarnings({"unchecked"})
final class Graphql {

  /** Content type every GraphQL-over-HTTP request uses. */
  static final String GRAPHQL_CONTENT_TYPE = "application/json";

  private Graphql() {}

  /**
   * Map a GraphQL error to the same error codes the HTTP path produces, so
   * a caller handles auth or rate limiting identically on both transports.
   * Servers put the machine-readable code in {@code extensions.code};
   * Linear-style APIs use {@code extensions.type}.
   */
  static String graphqlErrorCode(Object gqlerr) {
    Object ext = Struct.getprop(gqlerr, "extensions", null);

    Object code = Struct.getprop(ext, "code", null);
    if (null == code || "".equals(code)) {
      code = Struct.getprop(ext, "type", null);
    }

    String raw = (code instanceof String) ? ((String) code).toUpperCase() : "";

    if (raw.contains("AUTH") || raw.contains("FORBIDDEN")
        || raw.contains("UNAUTHENTICATED")) {
      return "request_auth";
    }
    if (raw.contains("RATELIMIT") || raw.contains("RATE_LIMIT")
        || raw.contains("TOO_MANY")) {
      return "request_ratelimit";
    }
    if (raw.contains("BAD_USER_INPUT") || raw.contains("VALIDATION")
        || raw.contains("INVALID")) {
      return "request_invalid";
    }

    return "request_graphql";
  }

  /**
   * Build the request body for a GraphQL point.
   *
   * <p>Variables come from the op's own arguments: a named variable binds to
   * the like-named argument ({@code from}), and the input-object variable
   * (empty {@code from}) takes the request data as a whole — which is what
   * makes a generated create/update call look exactly like its REST
   * equivalent.
   */
  static Object graphqlBody(Context ctx) {
    Object gql = Struct.getprop(ctx.point, "graphql", null);

    if (!(gql instanceof Map)) {
      return null;
    }

    // reqmatch/reqdata hold the caller's arguments for THIS call; data/match
    // hold the entity's current state. Which pair depends on whether the op
    // takes match or data input. A named variable falls back to the current
    // state, so updating a loaded entity with just {title} still binds the
    // stored id the mutation requires.
    Map<String, Object> reqsrc = ctx.reqmatch;
    Map<String, Object> datasrc = ctx.match;
    if (null != ctx.op && "data".equals(ctx.op.input)) {
      reqsrc = ctx.reqdata;
      datasrc = ctx.data;
    }
    if (null == reqsrc) {
      reqsrc = new LinkedHashMap<>();
    }
    if (null == datasrc) {
      datasrc = new LinkedHashMap<>();
    }

    Map<String, Object> variables = new LinkedHashMap<>();

    Object rawvars = Struct.getprop(gql, "vars", null);
    List<Object> varlist =
        (rawvars instanceof List) ? (List<Object>) rawvars : new ArrayList<>();

    for (Object spec : varlist) {
      if (!(spec instanceof Map)) {
        continue;
      }

      Object nameval = Struct.getprop(spec, "name", null);
      String name = (nameval instanceof String) ? (String) nameval : "";

      Object fromval = Struct.getprop(spec, "from", null);
      String from = (fromval instanceof String) ? (String) fromval : "";

      if ("".equals(from)) {
        // The input object IS the request body. Strip the action selector,
        // which is an SDK-side point discriminator, not an API field.
        Map<String, Object> body = new LinkedHashMap<>();
        for (Map.Entry<String, Object> e : reqsrc.entrySet()) {
          if (!"$action".equals(e.getKey())) {
            body.put(e.getKey(), e.getValue());
          }
        }
        variables.put(name, body);
        continue;
      }

      // Only send variables the caller actually supplied: sending an
      // explicit null would clear a field on many APIs.
      Object val = Struct.getprop(reqsrc, from, null);
      if (null == val) {
        val = Struct.getprop(datasrc, from, null);
      }
      if (null != val) {
        variables.put(name, val);
      }
    }

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("query", Struct.getprop(gql, "doc", null));
    out.put("variables", variables);

    return out;
  }

  /**
   * Inspect a decoded GraphQL response body and record a failure when the
   * server reported one. Returns true when an error was recorded.
   *
   * <p>Partial data ({@code data} alongside {@code errors}) is treated as
   * failure: the REST surface has no partial-success concept, and silently
   * returning half an object would be worse than failing. The raw envelope
   * stays available on the result for callers that need it.
   */
  static Result graphqlErrors(Context ctx) {
    Result result = ctx.result;

    if (null == result || null == ctx.point) {
      return result;
    }

    if (!"graphql".equals(Struct.getprop(ctx.point, "kind", null))) {
      return result;
    }

    Object rawerrors = Struct.getprop(result.body, "errors", null);
    if (!(rawerrors instanceof List)) {
      return result;
    }

    List<Object> errors = (List<Object>) rawerrors;
    if (0 == errors.size()) {
      return result;
    }

    Object first = errors.get(0);
    Object msgval = Struct.getprop(first, "message", null);
    String msg = (msgval instanceof String) ? (String) msgval : "graphql error";
    if (1 < errors.size()) {
      msg = msg + " (+" + (errors.size() - 1) + " more)";
    }

    result.err = ctx.makeError(graphqlErrorCode(first), "graphql: " + msg);
    result.ok = false;

    return result;
  }
}
