// prepare_query utility (mirrors utility/prepare_query.rs).

#include "sdk.h"

#include <string.h>

static bool params_contains(voxgig_value* params, const char* key) {
  if (voxgig_is_list(params)) {
    voxgig_list* pl = voxgig_as_list(params);
    for (size_t i = 0; i < pl->len; i++) {
      voxgig_value* v = pl->items[i];
      if (voxgig_is_string(v) && strcmp(voxgig_as_string(v), key) == 0) return true;
    }
  }
  return false;
}

voxgig_value* prepare_query_util(Context* ctx) {
  voxgig_value* point = ctx->point;
  voxgig_value* reqmatch = voxgig_is_map(ctx->reqmatch) ? ctx->reqmatch : voxgig_new_map();

  voxgig_value* params = getp(point, "params");
  if (!voxgig_is_list(params)) params = voxgig_new_list();

  voxgig_value* out = voxgig_new_map();
  if (voxgig_is_map(reqmatch)) {
    voxgig_map* rm = voxgig_as_map(reqmatch);
    for (size_t i = 0; i < rm->len; i++) {
      const char* key = rm->entries[i].key;
      voxgig_value* val = rm->entries[i].value;
      if (!v_is_noval(val) && !v_is_null(val) && !params_contains(params, key)) {
        setp(out, key, v_share(val));
      }
    }
  }
  return out;
}
