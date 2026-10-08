// clean utility (mirrors utility/clean.rs).
//
// Everything that leaves the pipeline passes through clean: the error, the
// explain record, the serialised context, and whatever a feature emits.
// Two layers: every registered secret VALUE (and its encoded forms) is
// replaced wherever it appears in a string, and every value under a
// sensitive KEY name is masked whatever it holds. Inside the pipeline data
// stays raw, so a hook can still read the header it must add to.
//
// The registry is the `values` list of the derived clean block that
// make_options builds (`options.__derived__.clean`). Nodes are shared by
// pointer, so a feature registering a value later reaches the same list
// every context reads.

#include "sdk.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CLEAN_MAXDEPTH 32
#define CLEAN_CIRCULAR "[circular]"
#define CLEAN_DEFAULT_MASK "[redacted]"

typedef struct {
  bool active;
  voxgig_value* keys;   // List of normalised names
  voxgig_value* values; // List of registered forms, longest first
  const char* mask;
  int64_t hint;
  int64_t min;
} CleanCfg;

static char* dup_str(const char* s) {
  if (!s) s = "";
  size_t n = strlen(s);
  char* d = (char*)malloc(n + 1);
  memcpy(d, s, n + 1);
  return d;
}

static char* normkey(const char* key) {
  size_t n = strlen(key);
  char* out = (char*)malloc(n + 1);
  size_t o = 0;
  for (size_t i = 0; i < n; i++) {
    char c = key[i];
    if ('-' == c || '_' == c) continue;
    out[o++] = (char)tolower((unsigned char)c);
  }
  out[o] = '\0';
  return out;
}

// A comma-separated string as a list of trimmed, non-empty entries; a list
// is taken as-is.
static voxgig_value* strs(voxgig_value* val) {
  voxgig_value* out = v_list();
  if (voxgig_is_list(val)) {
    voxgig_list* l = voxgig_as_list(val);
    for (size_t i = 0; i < l->len; i++) {
      if (voxgig_is_string(l->items[i])) {
        voxgig_list_push(voxgig_as_list(out), voxgig_retain(l->items[i]));
      }
    }
    return out;
  }
  if (!voxgig_is_string(val)) return out;
  const char* p = voxgig_as_string(val);
  while (1) {
    const char* comma = strchr(p, ',');
    const char* start = p;
    const char* end = comma ? comma : p + strlen(p);
    while (start < end && isspace((unsigned char)*start)) start++;
    while (end > start && isspace((unsigned char)end[-1])) end--;
    if (end > start) {
      voxgig_list_push(voxgig_as_list(out), voxgig_new_string_n(start, (size_t)(end - start)));
    }
    if (!comma) break;
    p = comma + 1;
  }
  return out;
}

voxgig_value* clean_split_values(voxgig_value* values) { return strs(values); }

// The spec carries numbers as strings, so every target reads it alike.
static int64_t count(voxgig_value* val, int64_t dflt) {
  double n;
  if (voxgig_is_int(val)) {
    n = (double)voxgig_as_int(val);
  } else if (voxgig_is_double(val)) {
    n = voxgig_as_double(val);
  } else if (voxgig_is_string(val)) {
    char* end = NULL;
    const char* s = voxgig_as_string(val);
    n = strtod(s, &end);
    if (end == s) return dflt;
  } else {
    return dflt;
  }
  if (n != n || n < 0) return dflt;
  return (int64_t)n;
}

voxgig_value* clean_make_config(voxgig_value* cleanopts) {
  voxgig_value* activev = getp(cleanopts, "active");
  bool active = !(voxgig_is_bool(activev) && !voxgig_as_bool(activev));
  const char* mask = get_str(cleanopts, "mask");
  if (!mask) mask = CLEAN_DEFAULT_MASK;

  voxgig_value* keys = v_list();
  voxgig_value* rawkeys = strs(getp(cleanopts, "keys"));
  voxgig_list* rl = voxgig_as_list(rawkeys);
  for (size_t i = 0; i < rl->len; i++) {
    char* nk = normkey(voxgig_as_string(rl->items[i]));
    if (nk[0] != '\0') voxgig_list_push(voxgig_as_list(keys), v_str(nk));
    free(nk);
  }

  int64_t min = count(getp(cleanopts, "min"), 4);
  if (min < 1) min = 1;

  return cmap(6,
    "active", v_bool(active),
    "keys", keys,
    "values", v_list(),
    "mask", v_str(mask),
    "hint", v_int(count(getp(cleanopts, "hint"), 0)),
    "min", v_int(min));
}

static voxgig_value* derived_block(voxgig_value* options) {
  return getpath2(options, "__derived__", "clean");
}

// A context without options (make_error is reached with a bare one) falls
// back to the schema defaults, so nothing leaves raw for want of a
// constructor.
static voxgig_value* config_block(Context* ctx) {
  voxgig_value* derived = ctx ? derived_block(ctx->options) : NULL;
  if (voxgig_is_map(derived)) return derived;
  return clean_make_config(getp(shared_optspec(), "clean"));
}

static void read_cfg(voxgig_value* block, CleanCfg* cfg) {
  voxgig_value* activev = getp(block, "active");
  cfg->active = !(voxgig_is_bool(activev) && !voxgig_as_bool(activev));
  cfg->keys = strs(getp(block, "keys"));
  cfg->values = strs(getp(block, "values"));
  cfg->mask = get_str(block, "mask");
  if (!cfg->mask) cfg->mask = CLEAN_DEFAULT_MASK;
  cfg->hint = count(getp(block, "hint"), 0);
  cfg->min = count(getp(block, "min"), 4);
  if (cfg->min < 1) cfg->min = 1;
}

// Standard base64 (RFC 4648), for the encoded form of a registered value
// and for the `Authorization: Basic` composite. Returns a malloc'd string.
char* clean_base64(const char* in) {
  static const char ALPHABET[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t n = strlen(in);
  char* out = (char*)malloc((n + 2) / 3 * 4 + 1);
  size_t o = 0;
  for (size_t i = 0; i < n; i += 3) {
    unsigned int v = (unsigned char)in[i] << 16;
    if (i + 1 < n) v |= (unsigned int)(unsigned char)in[i + 1] << 8;
    if (i + 2 < n) v |= (unsigned int)(unsigned char)in[i + 2];
    out[o++] = ALPHABET[(v >> 18) & 0x3f];
    out[o++] = ALPHABET[(v >> 12) & 0x3f];
    out[o++] = (i + 1 < n) ? ALPHABET[(v >> 6) & 0x3f] : '=';
    out[o++] = (i + 2 < n) ? ALPHABET[v & 0x3f] : '=';
  }
  out[o] = '\0';
  return out;
}

// The encoded forms a value travels in: Basic and Bearer both carry base64,
// a query credential is percent-encoded, and a JSON dump escapes it.
static voxgig_value* forms(const char* value) {
  voxgig_value* out = v_list();
  voxgig_list* l = voxgig_as_list(out);
  voxgig_list_push(l, v_str(value));

  char* b64 = clean_base64(value);
  char* url = voxgig_escurl(v_str(value));
  char* json = voxgig_jsonify(v_str(value), NULL);
  char* cands[3] = { b64, url, NULL };
  size_t jn = json ? strlen(json) : 0;
  if (2 <= jn) {
    json[jn - 1] = '\0';
    cands[2] = json + 1;
  }
  for (int c = 0; c < 3; c++) {
    const char* s = cands[c];
    if (!s || s[0] == '\0') continue;
    bool present = false;
    for (size_t i = 0; i < l->len; i++) {
      if (0 == strcmp(voxgig_as_string(l->items[i]), s)) { present = true; break; }
    }
    if (!present) voxgig_list_push(l, v_str(s));
  }
  free(b64);
  free(url);
  free(json);
  return out;
}

static int longest_first(const void* a, const void* b) {
  voxgig_value* va = *(voxgig_value* const*)a;
  voxgig_value* vb = *(voxgig_value* const*)b;
  size_t la = voxgig_is_string(va) ? voxgig_string_len(va) : 0;
  size_t lb = voxgig_is_string(vb) ? voxgig_string_len(vb) : 0;
  return la < lb ? 1 : (la > lb ? -1 : 0);
}

// Register a secret value against an options map. Idempotent; shorter
// than `min` is not a secret the SDK can mask without blanking ordinary
// text. A map with no derived block registers nothing.
void clean_add_opts(voxgig_value* options, const char* value) {
  if (!value) return;
  voxgig_value* block = derived_block(options);
  if (!voxgig_is_map(block)) return;
  int64_t min = count(getp(block, "min"), 4);
  if (min < 1) min = 1;
  if ((int64_t)strlen(value) < min) return;

  voxgig_value* list = getp(block, "values");
  if (!voxgig_is_list(list)) {
    list = v_list();
    setp(block, "values", list);
  }
  voxgig_list* l = voxgig_as_list(list);

  bool changed = false;
  voxgig_list* fl = voxgig_as_list(forms(value));
  for (size_t i = 0; i < fl->len; i++) {
    const char* form = voxgig_as_string(fl->items[i]);
    if ((int64_t)strlen(form) < min) continue;
    bool present = false;
    for (size_t j = 0; j < l->len; j++) {
      if (voxgig_is_string(l->items[j]) && 0 == strcmp(voxgig_as_string(l->items[j]), form)) {
        present = true;
        break;
      }
    }
    if (!present) {
      voxgig_list_push(l, v_str(form));
      changed = true;
    }
  }
  if (changed && 1 < l->len) {
    qsort(l->items, l->len, sizeof(voxgig_value*), longest_first);
  }
}

// Register a secret value the context's options will mask from now on.
void clean_add_util(Context* ctx, const char* value) {
  if (!ctx) return;
  clean_add_opts(ctx->options, value);
}

static char* mask_value(const CleanCfg* cfg, const char* value) {
  size_t n = strlen(value);
  if (0 < cfg->hint && (int64_t)n > 2 * cfg->hint) {
    size_t ml = strlen(cfg->mask);
    char* out = (char*)malloc(ml + (size_t)cfg->hint + 1);
    memcpy(out, cfg->mask, ml);
    memcpy(out + ml, value + n - (size_t)cfg->hint, (size_t)cfg->hint);
    out[ml + (size_t)cfg->hint] = '\0';
    return out;
  }
  return dup_str(cfg->mask);
}

static char* replace_all(const char* text, const char* from, const char* to) {
  size_t fl = strlen(from);
  size_t tl = strlen(to);
  size_t cap = strlen(text) + 1;
  char* out = (char*)malloc(cap);
  size_t o = 0;
  const char* p = text;
  while (1) {
    const char* hit = strstr(p, from);
    size_t seg = hit ? (size_t)(hit - p) : strlen(p);
    if (o + seg + tl + 1 > cap) {
      cap = (o + seg + tl + 1) * 2;
      out = (char*)realloc(out, cap);
    }
    memcpy(out + o, p, seg);
    o += seg;
    if (!hit) break;
    memcpy(out + o, to, tl);
    o += tl;
    p = hit + fl;
  }
  out[o] = '\0';
  return out;
}

static char* clean_string(const CleanCfg* cfg, const char* text) {
  char* out = dup_str(text);
  voxgig_list* vl = voxgig_as_list(cfg->values);
  for (size_t i = 0; i < vl->len; i++) {
    const char* value = voxgig_as_string(vl->items[i]);
    if (value[0] != '\0' && strstr(out, value)) {
      char* masked = mask_value(cfg, value);
      char* next = replace_all(out, value, masked);
      free(masked);
      free(out);
      out = next;
    }
  }
  return out;
}

static bool sensitive_key(const CleanCfg* cfg, const char* key) {
  if (!key) return false;
  char* nk = normkey(key);
  bool hit = false;
  voxgig_list* kl = voxgig_as_list(cfg->keys);
  for (size_t i = 0; i < kl->len; i++) {
    if (strstr(nk, voxgig_as_string(kl->items[i]))) { hit = true; break; }
  }
  free(nk);
  return hit;
}

typedef struct {
  const void* ptrs[CLEAN_MAXDEPTH + 1];
  size_t n;
} Seen;

static const void* node_ptr(voxgig_value* val) {
  if (voxgig_is_list(val)) return (const void*)voxgig_as_list(val);
  if (voxgig_is_map(val)) return (const void*)voxgig_as_map(val);
  return NULL;
}

static bool seen_has(const Seen* seen, const void* p) {
  for (size_t i = 0; i < seen->n; i++) {
    if (seen->ptrs[i] == p) return true;
  }
  return false;
}

// A registered value used as a property name is masked like any other
// string; names that mask alike take a counter, so none is lost.
static char* clean_name(const CleanCfg* cfg, voxgig_value* out, const char* key) {
  char* name = clean_string(cfg, key);
  voxgig_map* om = voxgig_as_map(out);
  if (0 == strcmp(name, key) || !voxgig_map_get(om, name)) return name;
  size_t cap = strlen(name) + 24;
  char* alt = (char*)malloc(cap);
  for (size_t i = 1;; i++) {
    snprintf(alt, cap, "%s#%zu", name, i);
    if (!voxgig_map_get(om, alt)) break;
  }
  free(name);
  return alt;
}

// A plain-data copy of what is about to leave: functions are dropped
// (NULL), cycles are cut, and no live node is shared with the copy -
// masking the copy must never mask the pipeline's own spec.
static voxgig_value* snapshot(const CleanCfg* cfg, voxgig_value* val, const char* key,
                              size_t depth, Seen* seen) {
  if (!val || voxgig_is_undef(val) || voxgig_is_null(val)) return val;

  if (voxgig_is_string(val)) {
    char* s = sensitive_key(cfg, key) ? mask_value(cfg, voxgig_as_string(val))
                                      : clean_string(cfg, voxgig_as_string(val));
    voxgig_value* out = v_str(s);
    free(s);
    return out;
  }

  if (voxgig_is_func(val)) return NULL;

  if (!voxgig_is_list(val) && !voxgig_is_map(val)) {
    return sensitive_key(cfg, key) ? v_str(cfg->mask) : val;
  }

  const void* ptr = node_ptr(val);
  if (CLEAN_MAXDEPTH <= depth || seen_has(seen, ptr)) return v_str(CLEAN_CIRCULAR);
  if (sensitive_key(cfg, key)) return v_str(cfg->mask);

  seen->ptrs[seen->n++] = ptr;
  voxgig_value* out;
  if (voxgig_is_list(val)) {
    out = v_list();
    voxgig_list* l = voxgig_as_list(val);
    for (size_t i = 0; i < l->len; i++) {
      voxgig_value* cv = snapshot(cfg, l->items[i], NULL, depth + 1, seen);
      if (cv) voxgig_list_push(voxgig_as_list(out), voxgig_retain(cv));
    }
  } else {
    out = v_map();
    voxgig_map* m = voxgig_as_map(val);
    for (size_t i = 0; i < m->len; i++) {
      voxgig_value* cv = snapshot(cfg, m->entries[i].value, m->entries[i].key, depth + 1, seen);
      if (cv) {
        char* name = clean_name(cfg, out, m->entries[i].key);
        setp(out, name, cv);
        free(name);
      }
    }
  }
  seen->n--;
  return out;
}

static voxgig_value* clean_with(const CleanCfg* cfg, voxgig_value* val) {
  if (!cfg->active) return val;
  if (voxgig_is_string(val)) {
    char* s = clean_string(cfg, voxgig_as_string(val));
    voxgig_value* out = v_str(s);
    free(s);
    return out;
  }
  Seen seen;
  seen.n = 0;
  voxgig_value* out = snapshot(cfg, val, NULL, 0, &seen);
  return out ? out : v_undef();
}

// Clean a value on its way out. A string is redacted; anything else comes
// back as a masked plain-data copy.
voxgig_value* clean_util(Context* ctx, voxgig_value* val) {
  CleanCfg cfg;
  read_cfg(config_block(ctx), &cfg);
  return clean_with(&cfg, val);
}

char* clean_str(Context* ctx, const char* val) {
  if (!val) val = "";
  CleanCfg cfg;
  read_cfg(config_block(ctx), &cfg);
  if (!cfg.active) return dup_str(val);
  return clean_string(&cfg, val);
}

// Clean a value against an options map rather than a context, for a
// feature that holds the options but no context.
voxgig_value* clean_opts(voxgig_value* options, voxgig_value* val) {
  voxgig_value* block = derived_block(options);
  if (!voxgig_is_map(block)) return val;
  CleanCfg cfg;
  read_cfg(block, &cfg);
  return clean_with(&cfg, val);
}

// Is this key name sensitive under the context's clean configuration?
bool clean_key_util(Context* ctx, const char* key) {
  CleanCfg cfg;
  read_cfg(config_block(ctx), &cfg);
  return sensitive_key(&cfg, key);
}

// An error that never passed through make_error, cleaned in place: every
// text field and both snapshots.
void clean_error_util(Context* ctx, PNError* err) {
  if (!err) return;
  CleanCfg cfg;
  read_cfg(config_block(ctx), &cfg);
  if (!cfg.active) return;
  char* msg = clean_string(&cfg, err->msg ? err->msg : "");
  free(err->msg);
  err->msg = msg;
  char* code = clean_string(&cfg, err->code ? err->code : "");
  free(err->code);
  err->code = code;
  if (err->result) err->result = clean_with(&cfg, err->result);
  if (err->spec) err->spec = clean_with(&cfg, err->spec);
}

typedef struct {
  const void** ptrs;
  size_t n;
  size_t cap;
} Visited;

static void add_sensitive(const CleanCfg* cfg, voxgig_value* options, voxgig_value* val,
                          bool under, size_t depth, Visited* seen) {
  if (!val || CLEAN_MAXDEPTH <= depth) return;
  if (voxgig_is_string(val)) {
    if (under) clean_add_opts(options, voxgig_as_string(val));
    return;
  }
  if (voxgig_is_number(val)) {
    if (under) {
      char* text = voxgig_stringify(val, -1);
      clean_add_opts(options, text);
      free(text);
    }
    return;
  }
  if (!voxgig_is_list(val) && !voxgig_is_map(val)) return;

  const void* ptr = node_ptr(val);
  for (size_t i = 0; i < seen->n; i++) {
    if (seen->ptrs[i] == ptr) return;
  }
  if (seen->n == seen->cap) {
    seen->cap = seen->cap ? seen->cap * 2 : 16;
    seen->ptrs = (const void**)realloc((void*)seen->ptrs, seen->cap * sizeof(void*));
  }
  seen->ptrs[seen->n++] = ptr;

  if (voxgig_is_list(val)) {
    voxgig_list* l = voxgig_as_list(val);
    for (size_t i = 0; i < l->len; i++) {
      add_sensitive(cfg, options, l->items[i], under, depth + 1, seen);
    }
  } else {
    voxgig_map* m = voxgig_as_map(val);
    for (size_t i = 0; i < m->len; i++) {
      bool sub = under || sensitive_key(cfg, m->entries[i].key);
      add_sensitive(cfg, options, m->entries[i].value, sub, depth + 1, seen);
    }
  }
}

// Every scalar under a sensitive name, at any depth and of any shape, is
// registered against `options`: a credential mistyped as a map or a number
// is still a credential.
void clean_add_sensitive_opts(voxgig_value* options, voxgig_value* val) {
  voxgig_value* block = derived_block(options);
  if (!voxgig_is_map(block)) return;
  CleanCfg cfg;
  read_cfg(block, &cfg);
  Visited seen = { NULL, 0, 0 };
  add_sensitive(&cfg, options, val, false, 0, &seen);
  free((void*)seen.ptrs);
}

void clean_add_sensitive_util(Context* ctx, voxgig_value* val) {
  if (!ctx) return;
  clean_add_sensitive_opts(ctx->options, val);
}
