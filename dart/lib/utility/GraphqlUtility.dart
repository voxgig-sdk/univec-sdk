import 'voxgig_struct.dart' as vs;

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
const String graphqlContentType = 'application/json';

// Map a GraphQL error to the same error codes the HTTP path produces, so a
// caller handles auth or rate limiting identically on both transports.
// Servers put the machine-readable code in `extensions.code`; Linear-style
// APIs use `extensions.type`.
String graphqlErrorCode(dynamic gqlerr) {
  final ext = vs.getprop(gqlerr, 'extensions');

  var raw = vs.getprop(ext, 'code');
  if (null == raw || '' == raw) {
    raw = vs.getprop(ext, 'type');
  }
  final code = (raw is String) ? raw.toUpperCase() : '';

  if (code.contains('AUTH') ||
      code.contains('FORBIDDEN') ||
      code.contains('UNAUTHENTICATED')) {
    return 'request_auth';
  }
  if (code.contains('RATELIMIT') ||
      code.contains('RATE_LIMIT') ||
      code.contains('TOO_MANY')) {
    return 'request_ratelimit';
  }
  if (code.contains('BAD_USER_INPUT') ||
      code.contains('VALIDATION') ||
      code.contains('INVALID')) {
    return 'request_invalid';
  }

  return 'request_graphql';
}

// Build the request body for a GraphQL point.
//
// Variables come from the op's own arguments: a named variable binds to the
// like-named argument (`from`), and the input-object variable (empty
// `from`) takes the request data as a whole — which is what makes a
// generated create/update call look exactly like its REST equivalent.
dynamic graphqlBody(dynamic ctx) {
  final gql = ctx.point?.graphql;

  if (gql is! Map) {
    return null;
  }

  // reqmatch/reqdata hold the caller's arguments for THIS call; data/match
  // hold the entity's current state. Which pair depends on whether the op
  // takes match or data input. A named variable falls back to the current
  // state, so updating a loaded entity with just {title} still binds the
  // stored id the mutation requires.
  var reqsrc = ctx.reqmatch;
  var datasrc = ctx.match;
  if (null != ctx.op && 'data' == ctx.op.input) {
    reqsrc = ctx.reqdata;
    datasrc = ctx.data;
  }
  if (reqsrc is! Map) {
    reqsrc = <String, dynamic>{};
  }
  if (datasrc is! Map) {
    datasrc = <String, dynamic>{};
  }

  final variables = <String, dynamic>{};

  final varlist = vs.getprop(gql, 'vars');
  if (varlist is List) {
    for (final spec in varlist) {
      if (spec is! Map) {
        continue;
      }

      final name = vs.getprop(spec, 'name');
      final from = vs.getprop(spec, 'from');
      if (null == name) {
        continue;
      }

      if (null == from || '' == from) {
        // The input object IS the request body. Strip the action selector,
        // which is an SDK-side point discriminator, not an API field.
        final body = <String, dynamic>{};
        reqsrc.forEach((k, v) {
          if ('\$action' != k) {
            body[k.toString()] = v;
          }
        });
        variables[name.toString()] = body;
        continue;
      }

      // Only send variables the caller actually supplied: sending an
      // explicit null would clear a field on many APIs.
      final val = vs.getprop(reqsrc, from) ?? vs.getprop(datasrc, from);
      if (null != val) {
        variables[name.toString()] = val;
      }
    }
  }

  return {
    'query': vs.getprop(gql, 'doc'),
    'variables': variables,
  };
}

// Inspect a decoded GraphQL response body and record a failure when the
// server reported one. Returns true when an error was recorded.
//
// Partial data (`data` alongside `errors`) is treated as failure: the REST
// surface has no partial-success concept, and silently returning half an
// object would be worse than failing.
bool graphqlErrors(dynamic ctx) {
  final result = ctx.result;

  if (null == result || null == ctx.point) {
    return false;
  }

  if ('graphql' != ctx.point.kind) {
    return false;
  }

  final errors = vs.getprop(result.body, 'errors');
  if (errors is! List || 0 == errors.length) {
    return false;
  }

  final first = errors[0];
  var msg = vs.getprop(first, 'message');
  if (msg is! String || '' == msg) {
    msg = 'graphql error';
  }
  if (1 < errors.length) {
    msg = msg + ' (+' + (errors.length - 1).toString() + ' more)';
  }

  result.err = ctx.error(graphqlErrorCode(first), 'graphql: ' + msg);
  result.ok = false;

  return true;
}
