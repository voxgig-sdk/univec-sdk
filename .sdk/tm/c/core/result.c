// Operation result (mirrors core/result.rs).

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

SdkResult* result_new(voxgig_value* resmap) {
  SdkResult* r = (SdkResult*)calloc(1, sizeof(SdkResult));
  bool ok = false;
  get_bool(resmap, "ok", &ok);
  r->ok = ok;

  voxgig_value* status = getp(resmap, "status");
  r->status = v_is_noval(status) ? -1 : to_int(status);

  const char* st = get_str(resmap, "statusText");
  r->status_text = dup_str(st ? st : "");

  voxgig_value* headers = getp(resmap, "headers");
  r->headers = voxgig_is_map(headers) ? headers : voxgig_new_map();
  r->body = getp(resmap, "body");
  r->err = NULL;
  r->resdata = getp(resmap, "resdata");

  voxgig_value* resmatch = getp(resmap, "resmatch");
  r->resmatch = voxgig_is_map(resmatch) ? resmatch : voxgig_new_undef();

  r->paging = voxgig_new_undef();
  r->streaming = false;
  r->stream = NULL;
  r->stream_ud = NULL;
  return r;
}

voxgig_value* result_to_value(SdkResult* r) {
  voxgig_value* out = voxgig_new_map();
  setp(out, "ok", v_bool(r->ok));
  setp(out, "status", v_num((double)r->status));
  setp(out, "statusText", v_str(r->status_text));
  setp(out, "headers", v_share(r->headers));
  if (!v_is_noval(r->body)) setp(out, "body", v_share(r->body));
  if (r->err) {
    voxgig_value* em = voxgig_new_map();
    setp(em, "message", v_str(r->err->msg));
    setp(out, "err", em);
  }
  if (!v_is_noval(r->resdata)) setp(out, "resdata", v_share(r->resdata));
  if (!v_is_noval(r->resmatch)) setp(out, "resmatch", v_share(r->resmatch));
  if (!v_is_noval(r->paging)) setp(out, "paging", v_share(r->paging));
  return out;
}
