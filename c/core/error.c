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
