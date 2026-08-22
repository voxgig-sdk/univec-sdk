// prepare_params utility (mirrors utility/prepare_params.rs).

#include "sdk.h"

voxgig_value* prepare_params_util(Context* ctx) {
  voxgig_value* point = ctx->point;

  voxgig_value* args = to_map(getp(point, "args"));
  voxgig_value* params = voxgig_new_list();
  if (voxgig_is_map(args)) {
    voxgig_value* p = getp(args, "params");
    if (voxgig_is_list(p)) params = p;
  }

  voxgig_value* out = voxgig_new_map();
  if (voxgig_is_list(params)) {
    voxgig_list* pl = voxgig_as_list(params);
    for (size_t i = 0; i < pl->len; i++) {
      voxgig_value* pd = pl->items[i];
      voxgig_value* val = param_util(ctx, pd);
      if (!v_is_noval(val) && !v_is_null(val) && voxgig_is_map(pd)) {
        const char* name = get_str(pd, "name");
        if (name && name[0] != '\0') {
          setp(out, name, v_share(val));
        }
      }
    }
  }
  return out;
}
