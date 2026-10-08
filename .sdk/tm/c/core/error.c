// UnivecError — the SDK error type (mirrors core/error.rs).

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

static char* dup_str(const char* s) {
  if (!s) s = "";
  size_t n = strlen(s);
  char* d = (char*)malloc(n + 1);
  memcpy(d, s, n + 1);
  return d;
}

PNError* pn_error_new(const char* code, const char* msg) {
  PNError* e = (PNError*)calloc(1, sizeof(PNError));
  e->sdk = dup_str("Univec");
  e->code = dup_str(code);
  e->msg = dup_str(msg);
  e->result = NULL;
  e->spec = NULL;
  return e;
}

// What make_error attached is already cleaned; the error carries no
// context.
voxgig_value* pn_error_to_value(PNError* e) {
  if (!e) return voxgig_new_undef();
  return cmap(5,
    "sdk", v_str(e->sdk),
    "code", v_str(e->code),
    "message", v_str(e->msg),
    "result", e->result ? v_share(e->result) : voxgig_new_undef(),
    "spec", e->spec ? v_share(e->spec) : voxgig_new_undef());
}

char* pn_error_str(PNError* e) {
  return voxgig_jsonify(pn_error_to_value(e), NULL);
}
