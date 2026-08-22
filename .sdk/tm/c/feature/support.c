// Shared option readers for feature implementations (mirrors
// feature/support.rs).

#include "sdk.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

bool fopt_bool(voxgig_value* options, const char* key, bool def) {
  voxgig_value* v = getp(options, key);
  if (voxgig_is_bool(v)) return voxgig_as_bool(v);
  return def;
}

int64_t fopt_int(voxgig_value* options, const char* key, int64_t def) {
  voxgig_value* v = getp(options, key);
  if (voxgig_is_number(v)) return to_int(v);
  return def;
}

double fopt_num(voxgig_value* options, const char* key, double def) {
  voxgig_value* v = getp(options, key);
  if (voxgig_is_int(v)) return (double)voxgig_as_int(v);
  if (voxgig_is_double(v)) return voxgig_as_double(v);
  return def;
}

const char* fopt_str(voxgig_value* options, const char* key, const char* def) {
  voxgig_value* v = getp(options, key);
  if (voxgig_is_string(v)) {
    const char* s = voxgig_as_string(v);
    if (s[0] != '\0') return s;
  }
  return def;
}

voxgig_value* fopt_map(voxgig_value* options, const char* key) {
  voxgig_value* v = getp(options, key);
  return voxgig_is_map(v) ? v : voxgig_new_undef();
}

voxgig_value* fopt_list(voxgig_value* options, const char* key) {
  voxgig_value* v = getp(options, key);
  return voxgig_is_list(v) ? v : voxgig_new_undef();
}

int64_t fopt_now_call(voxgig_value* options) {
  voxgig_value* f = getp(options, "now");
  if (voxgig_is_func(f)) {
    return to_int(call_vfn(f, voxgig_new_undef()));
  }
  return now_ms();
}

void fopt_sleep_call(voxgig_value* options, int64_t ms) {
  voxgig_value* f = getp(options, "sleep");
  if (voxgig_is_func(f)) {
    call_vfn(f, v_num((double)ms));
  } else if (ms > 0) {
    sleep_ms(ms);
  }
}

voxgig_value* fheader_get(voxgig_value* headers, const char* name) {
  if (voxgig_is_map(headers)) {
    voxgig_map* m = voxgig_as_map(headers);
    for (size_t i = 0; i < m->len; i++) {
      const char* k = m->entries[i].key;
      if (strcasecmp(k, name) == 0) {
        return voxgig_retain(m->entries[i].value);
      }
    }
  }
  return voxgig_new_undef();
}

void fheader_set_default(voxgig_value* headers, const char* name, const char* value) {
  if (!voxgig_is_map(headers)) return;
  voxgig_value* existing = fheader_get(headers, name);
  if (!v_is_noval(existing)) return;
  setp(headers, name, v_str(value));
}

bool fres_status(voxgig_value* res, int64_t* out) {
  voxgig_value* v = getp(res, "status");
  if (voxgig_is_number(v)) {
    if (out) *out = to_int(v);
    return true;
  }
  return false;
}

const char* fres_header(voxgig_value* res, const char* name) {
  voxgig_value* headers = getp(res, "headers");
  if (!voxgig_is_map(headers)) return NULL;
  voxgig_value* v = fheader_get(headers, name);
  if (voxgig_is_string(v)) return voxgig_as_string(v);
  return NULL;
}

int64_t fparse_int(const char* s, int64_t def) {
  if (!s) return def;
  while (*s == ' ' || *s == '\t') s++;
  char* end = NULL;
  long long v = strtoll(s, &end, 10);
  if (end == s) return def;
  return (int64_t)v;
}

// Test-support: dispatch to the feature's optional track() vtable slot.
voxgig_value* feature_track(Feature* f) {
  if (f && f->vt->track) return f->vt->track(f);
  return voxgig_new_undef();
}
