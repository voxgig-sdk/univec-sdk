// graphql utility (mirrors utility/GraphqlUtility.ts).
//
// GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
// produces uses this file unchanged. The API-specific part — which
// operations exist and what each one's document is — is model data,
// computed once by apidef and emitted into Config.
//
// Two jobs:
//
//   graphql_body_util   — build { query, variables } for a point, binding
//                         the op's arguments to the document's declared
//                         variables.
//
//   graphql_errors_util — lift a GraphQL failure into an SDK error.
//                         GraphQL reports failures as a top-level `errors`
//                         array under HTTP 200, so the status-driven path
//                         in result_basic never sees them.

#include "sdk.h"

#include <stdio.h>
#include <string.h>
#include <ctype.h>

// Uppercase copy, bounded. Used only to normalise an extension code.
static void upper_copy(const char* src, char* dst, size_t cap) {
  size_t i = 0;
  if (src != NULL) {
    for (; src[i] != '\0' && i + 1 < cap; i++) {
      dst[i] = (char)toupper((unsigned char)src[i]);
    }
  }
  dst[i] = '\0';
}

// Map a GraphQL error to the same error codes the HTTP path produces, so a
// caller handles auth or rate limiting identically on both transports.
// Servers put the machine-readable code in `extensions.code`; Linear-style
// APIs use `extensions.type`.
const char* graphql_error_code(voxgig_value* gqlerr) {
  voxgig_value* ext = getp(gqlerr, "extensions");

  voxgig_value* code = getp(ext, "code");
  if (!voxgig_is_string(code)) {
    code = getp(ext, "type");
  }

  char raw[128];
  upper_copy(voxgig_is_string(code) ? voxgig_as_string(code) : "", raw, sizeof(raw));

  if (strstr(raw, "AUTH") || strstr(raw, "FORBIDDEN") ||
      strstr(raw, "UNAUTHENTICATED")) {
    return "request_auth";
  }
  if (strstr(raw, "RATELIMIT") || strstr(raw, "RATE_LIMIT") ||
      strstr(raw, "TOO_MANY")) {
    return "request_ratelimit";
  }
  if (strstr(raw, "BAD_USER_INPUT") || strstr(raw, "VALIDATION") ||
      strstr(raw, "INVALID")) {
    return "request_invalid";
  }

  return "request_graphql";
}

// Build the request body for a GraphQL point.
//
// Variables come from the op's own arguments: a named variable binds to the
// like-named argument (`from`), and the input-object variable (empty
// `from`) takes the request data as a whole — which is what makes a
// generated create/update call look exactly like its REST equivalent.
voxgig_value* graphql_body_util(Context* ctx) {
  voxgig_value* gql = getp(ctx->point, "graphql");
  if (!voxgig_is_map(gql)) return voxgig_new_undef();

  // reqmatch/reqdata hold the caller's arguments for THIS call; data/match
  // hold the entity's current state. Which pair depends on whether the op
  // takes match or data input. A named variable falls back to the current
  // state, so updating a loaded entity with just {title} still binds the
  // stored id the mutation requires.
  voxgig_value* reqsrc = ctx->reqmatch;
  voxgig_value* datasrc = ctx->mtch;
  if (ctx->op != NULL && ctx->op->input != NULL &&
      strcmp(ctx->op->input, "data") == 0) {
    reqsrc = ctx->reqdata;
    datasrc = ctx->data;
  }
  if (!voxgig_is_map(reqsrc)) reqsrc = voxgig_new_map();
  if (!voxgig_is_map(datasrc)) datasrc = voxgig_new_map();

  voxgig_value* variables = voxgig_new_map();

  voxgig_value* varlist = getp(gql, "vars");
  if (voxgig_is_list(varlist)) {
    voxgig_list* vl = voxgig_as_list(varlist);
    for (size_t i = 0; i < vl->len; i++) {
      voxgig_value* spec = vl->items[i];
      if (!voxgig_is_map(spec)) continue;

      voxgig_value* nameval = getp(spec, "name");
      if (!voxgig_is_string(nameval)) continue;
      const char* name = voxgig_as_string(nameval);

      voxgig_value* fromval = getp(spec, "from");
      const char* from = voxgig_is_string(fromval) ? voxgig_as_string(fromval) : "";

      if (from[0] == '\0') {
        // The input object IS the request body. Strip the action selector,
        // which is an SDK-side point discriminator, not an API field.
        voxgig_value* body = voxgig_new_map();
        voxgig_map* rm = voxgig_as_map(reqsrc);
        for (size_t j = 0; j < rm->len; j++) {
          if (strcmp(rm->entries[j].key, "$action") != 0) {
            setp(body, rm->entries[j].key, v_share(rm->entries[j].value));
          }
        }
        setp(variables, name, body);
        continue;
      }

      // Only send variables the caller actually supplied: sending an
      // explicit null would clear a field on many APIs.
      voxgig_value* val = getp(reqsrc, from);
      if (v_is_noval(val) || v_is_null(val)) {
        val = getp(datasrc, from);
      }
      if (!v_is_noval(val) && !v_is_null(val)) {
        setp(variables, name, v_share(val));
      }
    }
  }

  voxgig_value* out = voxgig_new_map();
  setp(out, "query", v_share(getp(gql, "doc")));
  setp(out, "variables", variables);

  return out;
}

// Inspect a decoded GraphQL response body and record a failure when the
// server reported one. Returns true when an error was recorded.
//
// Partial data (`data` alongside `errors`) is treated as failure: the REST
// surface has no partial-success concept, and silently returning half an
// object would be worse than failing. The raw envelope stays available on
// the result for callers that need it.
bool graphql_errors_util(Context* ctx) {
  SdkResult* result = ctx->result;
  if (result == NULL || ctx->point == NULL) return false;

  voxgig_value* kind = getp(ctx->point, "kind");
  if (!voxgig_is_string(kind) || strcmp(voxgig_as_string(kind), "graphql") != 0) {
    return false;
  }

  voxgig_value* errors = getp(result->body, "errors");
  if (!voxgig_is_list(errors)) return false;

  voxgig_list* el = voxgig_as_list(errors);
  if (el->len == 0) return false;

  voxgig_value* first = el->items[0];
  voxgig_value* msgval = getp(first, "message");
  const char* msg = voxgig_is_string(msgval) ? voxgig_as_string(msgval) : "graphql error";

  char buf[512];
  if (el->len > 1) {
    snprintf(buf, sizeof(buf), "graphql: %s (+%zu more)", msg, el->len - 1);
  } else {
    snprintf(buf, sizeof(buf), "graphql: %s", msg);
  }

  result->err = context_make_error(ctx, graphql_error_code(first), buf);
  result->ok = false;

  return true;
}
