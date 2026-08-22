// param utility (mirrors utility/param.rs).

#include "sdk.h"

#include <stdio.h>   // snprintf
#include <string.h>

voxgig_value* param_util(Context* ctx, voxgig_value* paramdef) {
  voxgig_value* point = ctx->point;
  Spec* spec = ctx->spec;
  voxgig_value* mtch = ctx->mtch;
  voxgig_value* reqmatch = ctx->reqmatch;
  voxgig_value* data = ctx->data;
  voxgig_value* reqdata = ctx->reqdata;

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

  char akey[256];
  akey[0] = '\0';
  if (!v_is_noval(point)) {
    voxgig_value* alias = to_map(getp(point, "alias"));
    if (!v_is_noval(alias)) {
      const char* ak = get_str(alias, key);
      if (ak) snprintf(akey, sizeof(akey), "%s", ak);
    }
  }

  voxgig_value* val = getp(reqmatch, key);
  if (v_is_noval(val)) val = getp(mtch, key);

  if (v_is_noval(val) && akey[0] != '\0') {
    if (spec) {
      setp(spec->alias, akey, v_str(key));
    }
    val = getp(reqmatch, akey);
  }

  if (v_is_noval(val)) val = getp(reqdata, key);
  if (v_is_noval(val)) val = getp(data, key);

  if (v_is_noval(val) && akey[0] != '\0') {
    val = getp(reqdata, akey);
    if (v_is_noval(val)) val = getp(data, akey);
  }

  return val;
}
