// make_error utility (mirrors utility/make_error.rs). On success (throw ==
// false) returns resdata and *out = NULL; otherwise *out = the SDK error and
// returns NULL.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

voxgig_value* make_error_util(Context* ctx, PNError* err, PNError** out) {
  Operation* op = ctx->op;
  const char* opname = op->name;
  if (opname == NULL || opname[0] == '\0' || strcmp(opname, "_") == 0) {
    opname = "unknown operation";
  }

  SdkResult* result = ctx->result;
  if (!result) {
    result = result_new(voxgig_new_map());
    ctx->result = result;
  }
  result->ok = false;

  PNError* use = err;
  if (!use) use = result->err;
  if (!use) use = context_make_error(ctx, "unknown", "unknown error");

  const char* errmsg = use->msg;
  char msgbuf[1024];
  snprintf(msgbuf, sizeof(msgbuf), "UnivecSDK: %s: %s", opname, errmsg);
  char* msg = clean_str(ctx, msgbuf);

  result->err = NULL;

  voxgig_value* spec_val = ctx->spec ? spec_to_value(ctx->spec) : voxgig_new_undef();

  Control* c = ctx->ctrl;
  if (control_has_explain(c)) {
    setp(c->explain, "err", cmap(1, "message", v_str(msg)));
  }

  PNError* sdk_err = pn_error_new("", msg);
  free(sdk_err->code);
  size_t cn = strlen(use->code);
  sdk_err->code = (char*)malloc(cn + 1);
  memcpy(sdk_err->code, use->code, cn + 1);
  sdk_err->result = clean_util(ctx, result_to_value(result));
  sdk_err->spec = clean_util(ctx, spec_val);

  c->err = sdk_err;

  // Fire PreUnexpected so observability features (metrics, telemetry, audit,
  // debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  // rbac short-circuit). Fires after c->err is set so hooks can read the error;
  // features guard against double-recording when PreDone already fired.
  feature_hook_util(ctx, "PreUnexpected");

  if (c->has_throw && c->throw_v == false) {
    if (out) *out = NULL;
    return v_share(result->resdata);
  }

  if (out) *out = sdk_err;
  return NULL;
}
