// Idempotency keys for mutating operations (mirrors feature/idempotency.rs).
// Adds an `Idempotency-Key` header (name configurable via `header`) to unsafe
// requests so a server can de-duplicate retried writes. The key is set once,
// at PreRequest, before the request is built — so it is stable across
// transport-level retries of the same call. A caller-supplied header is never
// overwritten (case-insensitive). The key generator is injectable (`keygen`).

#include "sdk.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;

  // Activity tracking (mirrors the ts client._idempotency record).
  int64_t issued;
  char* last;
} IdempotencyFeature;

// ---- local string helpers -------------------------------------------------

static char* str_upper(const char* s) {
  size_t n = strlen(s);
  char* r = (char*)malloc(n + 1);
  for (size_t i = 0; i < n; i++) r[i] = (char)toupper((unsigned char)s[i]);
  r[n] = '\0';
  return r;
}

// Mirrors fopt_str_list(options,key).unwrap_or_else(defaults) followed by an
// `any(...)` membership test: when the option is a list, only its string
// elements are considered (defaults ignored); otherwise the defaults apply.
// Comparison is case-insensitive when `ci`.
static bool option_list_match(voxgig_value* options, const char* key,
                              const char* needle, const char** defaults,
                              size_t ndefaults, bool ci) {
  voxgig_value* lst = getp(options, key);
  if (voxgig_is_list(lst)) {
    voxgig_list* l = voxgig_as_list(lst);
    for (size_t i = 0; i < l->len; i++) {
      voxgig_value* item = l->items[i];
      if (voxgig_is_string(item)) {
        const char* s = voxgig_as_string(item);
        if (ci ? (strcasecmp(s, needle) == 0) : (strcmp(s, needle) == 0)) return true;
      }
    }
    return false;
  }
  for (size_t i = 0; i < ndefaults; i++) {
    if (ci ? (strcasecmp(defaults[i], needle) == 0) : (strcmp(defaults[i], needle) == 0))
      return true;
  }
  return false;
}

static bool idem_mutating(IdempotencyFeature* f, Context* ctx) {
  char* method = str_upper((ctx->spec && ctx->spec->method) ? ctx->spec->method : "");

  static const char* MDEF[] = {"POST", "PUT", "PATCH", "DELETE"};
  bool result;
  if (method[0] != '\0' &&
      option_list_match(f->options, "methods", method, MDEF, 4, true)) {
    result = true;
  } else {
    const char* opname = (ctx->op && ctx->op->name) ? ctx->op->name : "";
    static const char* ODEF[] = {"create", "update", "remove"};
    result = option_list_match(f->options, "ops", opname, ODEF, 3, false);
  }

  free(method);
  return result;
}

// genkey returns a malloc'd key string. Uses the injectable `keygen` when it
// is a Func returning a string, else a random 24-hex-digit key.
static char* idem_genkey(IdempotencyFeature* f) {
  voxgig_value* keygen = getp(f->options, "keygen");
  if (voxgig_is_func(keygen)) {
    voxgig_value* r = call_vfn(keygen, voxgig_new_undef());
    if (voxgig_is_string(r)) return strdup(voxgig_as_string(r));
  }

  char buf[32];
  snprintf(buf, sizeof(buf), "%06llx%06llx%06llx%06llx",
           (unsigned long long)rand_int(0x1000000),
           (unsigned long long)rand_int(0x1000000),
           (unsigned long long)rand_int(0x1000000),
           (unsigned long long)rand_int(0x1000000));
  buf[24] = '\0'; // key[..24]
  return strdup(buf);
}

static void idem_pre_request(IdempotencyFeature* f, Context* ctx) {
  if (!f->active) return;
  if (!ctx->spec) return; // spec None => nothing to do

  if (!idem_mutating(f, ctx)) return;

  const char* header = fopt_str(f->options, "header", "Idempotency-Key");

  voxgig_value* headers = ctx->spec->headers;
  if (!voxgig_is_map(headers)) {
    headers = voxgig_new_map();
    ctx->spec->headers = headers;
  }

  // Respect a key the caller already provided.
  voxgig_value* existing = fheader_get(headers, header);
  if (!v_is_noval(existing)) return;

  char* key = idem_genkey(f);
  setp(headers, header, v_str(key));

  f->issued += 1;
  free(f->last);
  f->last = key;
}

static const char* idem_name(Feature* f) { return ((IdempotencyFeature*)f)->name; }
static bool idem_active(Feature* f) { return ((IdempotencyFeature*)f)->active; }
static voxgig_value* idem_add_options(Feature* f) { return ((IdempotencyFeature*)f)->add_opts; }

static void idem_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  IdempotencyFeature* idf = (IdempotencyFeature*)f;
  idf->options = options;
  idf->active = fopt_bool(options, "active", false);
}

static void idem_hook(Feature* f, const char* name, Context* ctx) {
  if (strcmp(name, "PreRequest") == 0) {
    idem_pre_request((IdempotencyFeature*)f, ctx);
  }
}

static voxgig_value* idem_track(Feature* f) {
  IdempotencyFeature* idf = (IdempotencyFeature*)f;
  return cmap(2, "issued", v_num((double)idf->issued),
              "last", v_str(idf->last ? idf->last : ""));
}

static const FeatureVT IDEMPOTENCY_VT = {
  idem_name, idem_active, idem_add_options, idem_init, idem_hook,
  idem_track,
};

Feature* feature_idempotency_new(void) {
  IdempotencyFeature* idf = (IdempotencyFeature*)calloc(1, sizeof(IdempotencyFeature));
  idf->base.vt = &IDEMPOTENCY_VT;
  idf->name = strdup("idempotency");
  idf->active = true; // matches rust default (overridden by init from options)
  idf->add_opts = NULL;
  idf->options = voxgig_new_undef();
  idf->issued = 0;
  idf->last = NULL; // rust String::new()
  return (Feature*)idf;
}
