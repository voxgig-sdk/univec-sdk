// prepare_path utility (mirrors utility/prepare_path.rs). Returns malloc'd.

#include "sdk.h"

#include <stdlib.h>
#include <string.h>

char* prepare_path_util(Context* ctx) {
  voxgig_value* point = ctx->point;
  voxgig_value* parts = getp(point, "parts");
  if (!voxgig_is_list(parts)) parts = voxgig_new_list();
  char* joined = voxgig_join_v(parts, v_str("/"), v_bool(true));
  if (joined) return joined;
  char* empty = (char*)malloc(1);
  empty[0] = '\0';
  return empty;
}
