// param utility (mirrors utility/param.rs).

#include "sdk.h"

#include <stdio.h>   // snprintf
#include <string.h>

static const char* param_alias(voxgig_value* point, const char* key);

voxgig_value* param_util(Context* ctx, voxgig_value* paramdef) {
  int pt = voxgig_typify(paramdef);

  char key[256];
  key[0] = '\0';
  if (0 != ((VOXGIG_T_STRING) & pt)) {
    if (voxgig_is_string(paramdef)) {
      const char* s = voxgig_as_string(paramdef);
      snprintf(key, sizeof(key), "%s", s);
    }
  } else {
    const char* n = get_str(paramdef, "name");
    if (n) snprintf(key, sizeof(key), "%s", n);
  }

  const char* akey = param_alias(ctx->point, key);
  if (ctx->spec && akey &&
      v_is_noval(getp(ctx->reqmatch, key)) && v_is_noval(getp(ctx->mtch, key))) {
    setp(ctx->spec->alias, akey, v_str(key));
  }

  return param_value(ctx, ctx->point, key);
}

// The name a point gives a parameter in the call, if it renames it.
static const char* param_alias(voxgig_value* point, const char* key) {
  if (v_is_noval(point)) return NULL;
  voxgig_value* alias = to_map(getp(point, "alias"));
  if (v_is_noval(alias)) return NULL;
  const char* ak = get_str(alias, key);
  return (ak && ak[0] != '\0') ? ak : NULL;
}

// The value the call or its entity gives a point's parameter, under its name
// or the point's alias for it.
voxgig_value* param_value(Context* ctx, voxgig_value* point, const char* key) {
  const char* akey = param_alias(point, key);

  voxgig_value* val = getp(ctx->reqmatch, key);
  if (v_is_noval(val)) val = getp(ctx->mtch, key);
  if (v_is_noval(val) && akey) val = getp(ctx->reqmatch, akey);
  if (v_is_noval(val)) val = getp(ctx->reqdata, key);
  if (v_is_noval(val)) val = getp(ctx->data, key);

  if (v_is_noval(val) && akey) {
    val = getp(ctx->reqdata, akey);
    if (v_is_noval(val)) val = getp(ctx->data, akey);
  }

  return val;
}

// The arguments a point declares in one location, query or header, each as
// [name, wire, val]: the name it travels under and the value this call passes
// in its match or else its data. Unlike a path parameter, the entity's stored
// match and data never supply one.
voxgig_value* call_args(Context* ctx, const char* kind) {
  voxgig_value* out = voxgig_new_list();
  voxgig_value* defs = getpath2(ctx->point, "args", kind);
  if (!voxgig_is_list(defs)) return out;

  voxgig_list* dl = voxgig_as_list(defs);
  for (size_t i = 0; i < dl->len; i++) {
    voxgig_value* name = getp(dl->items[i], "name");
    if (!voxgig_is_string(name) || voxgig_as_string(name)[0] == '\0') continue;
    voxgig_value* orig = getp(dl->items[i], "orig");
    voxgig_value* wire = voxgig_is_string(orig) && voxgig_as_string(orig)[0] != '\0' ? orig : name;

    voxgig_value* val = getp(ctx->reqmatch, voxgig_as_string(name));
    if (v_is_noval(val) || v_is_null(val)) val = getp(ctx->reqdata, voxgig_as_string(name));
    voxgig_list_push(voxgig_as_list(out), clist(3, name, wire, val));
  }
  return out;
}
