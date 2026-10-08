// done utility (mirrors utility/done.rs).

#include "sdk.h"

voxgig_value* done_util(Context* ctx, PNError** err) {
  clean_explain_util(ctx);

  SdkResult* result = ctx->result;
  if (result && result->ok) {
    if (err) *err = NULL;
    return v_share(result->resdata);
  }

  return make_error_util(ctx, NULL, err);
}

// Clean the explain record in place. It is the caller's own map (Control
// keeps the pointer), so its entries are replaced by the cleaned copy's; with
// clean off the cleaned record is that map, already current.
void clean_explain_util(Context* ctx) {
  Control* c = ctx->ctrl;
  if (!control_has_explain(c)) return;
  voxgig_value* explain = c->explain;
  voxgig_value* cleaned = clean_util(ctx, explain);
  if (cleaned != explain && voxgig_is_map(cleaned)) {
    voxgig_map* em = voxgig_as_map(explain);
    // Clearing releases each value; pipeline code never frees one.
    for (size_t i = 0; i < em->len; i++) voxgig_retain(em->entries[i].value);
    voxgig_map_clear(em);
    voxgig_map* cm = voxgig_as_map(cleaned);
    for (size_t i = 0; i < cm->len; i++) {
      setp(explain, cm->entries[i].key, voxgig_retain(cm->entries[i].value));
    }
  }
  // explain.result is a result_to_value snapshot, never the live result.
  voxgig_value* res = getp(explain, "result");
  if (voxgig_is_map(res)) {
    voxgig_value* k = voxgig_new_string("err");
    voxgig_delprop(res, k);
    voxgig_release(k);
  }
}
