// prepare_method utility (mirrors utility/prepare_method.rs).

#include "sdk.h"

#include <ctype.h>
#include <string.h>

const char* prepare_method_util(Context* ctx) {
  const char* op = ctx->op->name;

  // The API definition is authoritative: a POST-only or PATCH-based API
  // exposes `update` as POST or PATCH, not the PUT the op name implies.
  // Only fall back to the op-name convention when the point has no method.
  // Uppercased into a static buffer so the returned pointer stays valid for
  // the caller's lifetime, matching the static-string contract above.
  const char* m = get_str(ctx->point, "method");
  if (m && '\0' != m[0]) {
    static char upper[16];
    size_t i = 0;
    for (; i < sizeof(upper) - 1 && '\0' != m[i]; i++) {
      upper[i] = (char)toupper((unsigned char)m[i]);
    }
    upper[i] = '\0';
    return upper;
  }

  if (strcmp(op, "create") == 0) return "POST";
  if (strcmp(op, "update") == 0) return "PUT";
  if (strcmp(op, "load") == 0) return "GET";
  if (strcmp(op, "list") == 0) return "GET";
  if (strcmp(op, "remove") == 0) return "DELETE";
  if (strcmp(op, "patch") == 0) return "PATCH";
  /* No GET catch-all: an unrecognised op must fall through to the
     allow.method gate, not be silently issued as a GET. */
  return "";
}
