// make_url utility (mirrors utility/make_url.rs). Returns a malloc'd URL.

#include "sdk.h"

#include <stdio.h>   // snprintf
#include <stdlib.h>
#include <string.h>

// Append `add` to a heap string `*buf` (realloc), returns new buffer.
static char* str_append(char* buf, const char* add) {
  size_t bl = buf ? strlen(buf) : 0;
  size_t al = strlen(add);
  char* nb = (char*)realloc(buf, bl + al + 1);
  memcpy(nb + bl, add, al + 1);
  return nb;
}

char* make_url_util(Context* ctx, PNError** err) {
  *err = NULL;
  Spec* spec = ctx->spec;
  if (!spec) {
    *err = context_make_error(ctx, "url_no_spec", "Expected context spec property to be defined.");
    return NULL;
  }
  SdkResult* result = ctx->result;
  if (!result) {
    *err = context_make_error(ctx, "url_no_result", "Expected context result property to be defined.");
    return NULL;
  }

  // join([base, prefix, path, suffix], "/", url=true)
  voxgig_value* parts = clist(4, v_str(spec->base), v_str(spec->prefix),
                              v_str(spec->path), v_str(spec->suffix));
  voxgig_value* sep = v_str("/");
  char* joined = voxgig_join_v(parts, sep, v_bool(true));
  char* url = str_append(NULL, joined ? joined : "");
  free(joined);

  voxgig_value* resmatch = voxgig_new_map();

  // Path params substitution.
  if (voxgig_is_map(spec->params)) {
    voxgig_map* pm = voxgig_as_map(spec->params);
    for (size_t i = 0; i < pm->len; i++) {
      const char* key = pm->entries[i].key;
      voxgig_value* val = pm->entries[i].value;
      if (!v_is_noval(val) && !v_is_null(val)) {
        // pattern: \{escaped_key\}
        char* esc_key = voxgig_escre(v_str(key));
        char pat[512];
        snprintf(pat, sizeof(pat), "\\{%s\\}", esc_key ? esc_key : key);
        free(esc_key);
        char* valstr = voxgig_stringify(val, -1);
        char* sub = voxgig_escurl(v_str(valstr ? valstr : ""));
        free(valstr);
        char* newurl = voxgig_re_replace(pat, url, sub ? sub : "");
        free(sub);
        if (newurl) { free(url); url = newurl; }
        setp(resmatch, key, v_share(val));
      }
    }
  }

  // Query string.
  const char* qsep = "?";
  if (voxgig_is_map(spec->query)) {
    voxgig_map* qm = voxgig_as_map(spec->query);
    for (size_t i = 0; i < qm->len; i++) {
      const char* key = qm->entries[i].key;
      voxgig_value* val = qm->entries[i].value;
      if (!v_is_noval(val) && !v_is_null(val)) {
        char* ekey = voxgig_escurl(v_str(key));
        char* valstr = voxgig_stringify(val, -1);
        char* eval = voxgig_escurl(v_str(valstr ? valstr : ""));
        free(valstr);
        char frag[1024];
        snprintf(frag, sizeof(frag), "%s%s=%s", qsep, ekey ? ekey : key, eval ? eval : "");
        free(ekey);
        free(eval);
        url = str_append(url, frag);
        qsep = "&";
        setp(resmatch, key, v_share(val));
      }
    }
  }

  result->resmatch = resmatch;
  return url;
}
