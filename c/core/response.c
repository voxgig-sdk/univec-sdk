// Transport response wrapper (mirrors core/response.rs).

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

Response* response_new(voxgig_value* resmap) {
  Response* r = (Response*)calloc(1, sizeof(Response));

  voxgig_value* status = getp(resmap, "status");
  r->status = v_is_noval(status) ? -1 : to_int(status);

  const char* st = get_str(resmap, "statusText");
  r->status_text = dup_str(st ? st : "");
  r->headers = getp(resmap, "headers");
  r->json = getp(resmap, "json");
  r->body = getp(resmap, "body");
  r->err = NULL;
  return r;
}
