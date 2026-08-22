// feature_init utility (mirrors utility/feature_init.rs).

#include "sdk.h"

void feature_init_util(Context* ctx, Feature* f) {
  const char* fname = f->vt->name(f);
  voxgig_value* fopts = voxgig_new_map();

  voxgig_value* options = ctx->options;
  if (voxgig_is_map(options)) {
    voxgig_value* feature_opts = to_map(getp(options, "feature"));
    if (voxgig_is_map(feature_opts)) {
      voxgig_value* fo = to_map(getp(feature_opts, fname));
      if (voxgig_is_map(fo)) fopts = fo;
    }
  }

  bool active = false;
  if (get_bool(fopts, "active", &active) && active) {
    f->vt->init(f, ctx, fopts);
  }
}
