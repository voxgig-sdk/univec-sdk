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

// A path parameter travels in the path. The generated config lists them as
// args.params, which prepare_params reads; params is the older list of names.
static bool args_params_contains(voxgig_value* aparams, const char* key) {
  if (voxgig_is_list(aparams)) {
    voxgig_list* pl = voxgig_as_list(aparams);
    for (size_t i = 0; i < pl->len; i++) {
      voxgig_value* name = getp(pl->items[i], "name");
      if (voxgig_is_string(name) && strcmp(voxgig_as_string(name), key) == 0) return true;
    }
  }
  return false;
}

// A header or cookie parameter travels in the headers, which prepare_headers
// fills, unless a query parameter shares its name: then both are sent.
static bool routed_elsewhere(voxgig_value* aheader, voxgig_value* acookie, voxgig_value* aquery,
                             const char* key) {
  return (args_params_contains(aheader, key) || args_params_contains(acookie, key)) &&
         !args_params_contains(aquery, key);
}

// A query parameter travels under the name the definition gives it, its orig,
// which the model may have renamed for the caller.
static const char* query_wire_name(voxgig_value* aquery, const char* key) {
  if (voxgig_is_list(aquery)) {
    voxgig_list* ql = voxgig_as_list(aquery);
    for (size_t i = 0; i < ql->len; i++) {
      voxgig_value* name = getp(ql->items[i], "name");
      voxgig_value* orig = getp(ql->items[i], "orig");
      if (voxgig_is_string(name) && voxgig_is_string(orig) &&
          strcmp(voxgig_as_string(name), key) == 0 && voxgig_as_string(orig)[0] != '\0') {
        return voxgig_as_string(orig);
      }
    }
  }
  return key;
}

voxgig_value* prepare_query_util(Context* ctx) {
  voxgig_value* point = ctx->point;
  voxgig_value* reqmatch = voxgig_is_map(ctx->reqmatch) ? ctx->reqmatch : voxgig_new_map();

  voxgig_value* params = getp(point, "params");
  if (!voxgig_is_list(params)) params = voxgig_new_list();
  voxgig_value* aparams = getpath2(point, "args", "params");
  voxgig_value* aheader = getpath2(point, "args", "header");
  voxgig_value* acookie = getpath2(point, "args", "cookie");
  voxgig_value* aquery = getpath2(point, "args", "query");

  voxgig_value* out = voxgig_new_map();
  if (voxgig_is_map(reqmatch)) {
    voxgig_map* rm = voxgig_as_map(reqmatch);
    for (size_t i = 0; i < rm->len; i++) {
      const char* key = rm->entries[i].key;
      voxgig_value* val = rm->entries[i].value;
      if (!v_is_noval(val) && !v_is_null(val) && strcmp(key, "$action") != 0 &&
          !params_contains(params, key) && !args_params_contains(aparams, key) &&
          !routed_elsewhere(aheader, acookie, aquery, key)) {
        setp(out, query_wire_name(aquery, key), v_share(val));
      }
    }
  }

  // A create or update passes its query arguments in its data.
  voxgig_value* qargs = call_args(ctx, "query");
  voxgig_list* ql = voxgig_as_list(qargs);
  for (size_t i = 0; i < ql->len; i++) {
    voxgig_list* arg = voxgig_as_list(ql->items[i]);
    const char* name = voxgig_as_string(arg->items[0]);
    voxgig_value* val = arg->items[2];
    if (!v_is_noval(val) && !v_is_null(val) && !params_contains(params, name) &&
        !args_params_contains(aparams, name) && !routed_elsewhere(aheader, acookie, aquery, name)) {
      setp(out, voxgig_as_string(arg->items[1]), v_share(val));
    }
  }
  voxgig_release(qargs);
  return out;
}
