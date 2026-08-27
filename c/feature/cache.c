// Response caching for safe (read) requests (mirrors feature/cache.rs).
// Wraps the active transport and serves a fresh cached snapshot instead of
// hitting the network when the same method+URL was fetched within `ttl` ms
// (default: 5000). Only successful (2xx) responses to cacheable methods
// (default: GET) are stored, keyed by method+URL. The cache is bounded (`max`
// entries, default 256, oldest evicted first) and every hit/miss/bypass is
// counted. Bodies are snapshotted on capture so both the current caller and
// later hits can re-read the JSON body repeatedly.

#include "sdk.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  // string-keyed store (voxgig_map, insertion-ordered) mapping
  // "METHOD url" -> { expiry: num, snap: <snapshot map> }.
  voxgig_value* store;
  // FIFO insertion order of keys (may contain duplicates, mirrors rust Vec).
  voxgig_value* order;

  // Activity tracking (mirrors the ts client._cache record).
  int64_t hit;
  int64_t miss;
  int64_t bypass;
} CacheTrack;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  CacheTrack* track;
} CacheFeature;

typedef struct {
  Fetcher* inner;
  voxgig_value* options;
  CacheTrack* track;
} CacheState;

// ---- local string helpers -------------------------------------------------

static char* str_upper(const char* s) {
  size_t n = strlen(s);
  char* r = (char*)malloc(n + 1);
  for (size_t i = 0; i < n; i++) r[i] = (char)toupper((unsigned char)s[i]);
  r[n] = '\0';
  return r;
}

static char* str_lower(const char* s) {
  size_t n = strlen(s);
  char* r = (char*)malloc(n + 1);
  for (size_t i = 0; i < n; i++) r[i] = (char)tolower((unsigned char)s[i]);
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

static bool storable(voxgig_value* res) {
  int64_t status;
  return fres_status(res, &status) && status >= 200 && status < 300;
}

// snapshot captures the response as a re-readable map:
// { status: num, statusText: str, data: <json>, headers: <lowercased map> }.
static voxgig_value* snapshot(voxgig_value* res) {
  voxgig_value* headers = voxgig_new_map();
  voxgig_value* rh = getp(res, "headers");
  if (voxgig_is_map(rh)) {
    voxgig_map* hm = voxgig_as_map(rh);
    for (size_t i = 0; i < hm->len; i++) {
      char* lower = str_lower(hm->entries[i].key);
      setp(headers, lower, hm->entries[i].value);
      free(lower);
    }
  }

  int64_t status = 0;
  fres_status(res, &status); // unwrap_or(0)
  const char* stext = get_str(res, "statusText");

  return cmap(4,
    "status", v_num((double)status),
    "statusText", v_str(stext ? stext : ""),
    "data", call_json(getp(res, "json")),
    "headers", headers);
}

// replay builds a fresh transport-shaped response so the body stays
// re-readable for every consumer.
static voxgig_value* replay(voxgig_value* snap) {
  voxgig_value* headers = voxgig_new_map();
  voxgig_value* sh = getp(snap, "headers");
  if (voxgig_is_map(sh)) {
    voxgig_map* hm = voxgig_as_map(sh);
    for (size_t i = 0; i < hm->len; i++) {
      setp(headers, hm->entries[i].key, hm->entries[i].value);
    }
  }

  int64_t status = to_int(getp(snap, "status"));
  const char* stext = get_str(snap, "statusText");

  return cmap(5,
    "status", v_num((double)status),
    "statusText", v_str(stext ? stext : ""),
    "body", v_str("not-used"),
    "json", json_thunk(getp(snap, "data")),
    "headers", headers);
}

// evict drops oldest entries (FIFO) until the store is under `max`.
static void evict(CacheTrack* t, voxgig_value* options) {
  int64_t max = fopt_int(options, "max", 256);
  voxgig_map* store = voxgig_as_map(t->store);
  voxgig_list* order = voxgig_as_list(t->order);
  while ((int64_t)store->len >= max && order->len > 0) {
    char* oldest = strdup(voxgig_as_string(order->items[0]));
    voxgig_list_erase(order, 0);
    voxgig_map_erase(store, oldest);
    free(oldest);
  }
}

static voxgig_value* through(Fetcher* self, Context* ctx, const char* url,
                             voxgig_value* fetchdef, PNError** err) {
  CacheState* st = (CacheState*)self->state;
  voxgig_value* options = st->options;
  CacheTrack* track = st->track;

  const char* mraw = get_str(fetchdef, "method");
  char* method = (mraw && mraw[0] != '\0') ? str_upper(mraw) : strdup("GET");

  static const char* MDEF[] = {"GET"};
  bool cacheable = option_list_match(options, "methods", method, MDEF, 1, true);
  if (!cacheable) {
    free(method);
    return st->inner->fn(st->inner, ctx, url, fetchdef, err);
  }

  size_t klen = strlen(method) + 1 + strlen(url) + 1;
  char* key = (char*)malloc(klen);
  snprintf(key, klen, "%s %s", method, url);
  free(method);

  int64_t now = fopt_now_call(options);

  voxgig_value* entry = voxgig_map_get(voxgig_as_map(track->store), key);
  if (entry) {
    int64_t expiry = to_int(getp(entry, "expiry"));
    if (expiry > now) {
      voxgig_value* snap = getp(entry, "snap");
      track->hit += 1;
      free(key);
      *err = NULL;
      return replay(snap);
    }
  }

  PNError* e = NULL;
  voxgig_value* out = st->inner->fn(st->inner, ctx, url, fetchdef, &e);

  if (!e && storable(out)) {
    voxgig_value* snap = snapshot(out);
    int64_t ttl = fopt_int(options, "ttl", 5000);
    evict(track, options);
    voxgig_value* newentry = cmap(2,
      "expiry", v_num((double)(now + ttl)),
      "snap", snap);
    voxgig_map_set(voxgig_as_map(track->store), key, newentry);
    voxgig_list_push(voxgig_as_list(track->order), v_str(key));
    track->miss += 1;
    free(key);
    *err = NULL;
    return replay(snap);
  }

  track->bypass += 1;
  free(key);
  *err = e;
  return out;
}

static const char* cache_name(Feature* f) { return ((CacheFeature*)f)->name; }
static bool cache_active(Feature* f) { return ((CacheFeature*)f)->active; }
static voxgig_value* cache_add_options(Feature* f) { return ((CacheFeature*)f)->add_opts; }

static void cache_init(Feature* f, Context* ctx, voxgig_value* options) {
  CacheFeature* cf = (CacheFeature*)f;
  cf->options = options;
  cf->active = fopt_bool(options, "active", false);
  if (!cf->active) return;

  Utility* util = context_util(ctx);
  CacheState* st = (CacheState*)calloc(1, sizeof(CacheState));
  st->inner = util->fetcher;
  st->options = options;
  st->track = cf->track;

  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  wrapped->fn = through;
  wrapped->state = st;
  util->fetcher = wrapped;
}

static void cache_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static voxgig_value* cache_track(Feature* f) {
  CacheTrack* t = ((CacheFeature*)f)->track;
  return cmap(3, "hit", v_num((double)t->hit), "miss", v_num((double)t->miss),
              "bypass", v_num((double)t->bypass));
}

static const FeatureVT CACHE_VT = {
  cache_name, cache_active, cache_add_options, cache_init, cache_hook,
  cache_track,
};

Feature* feature_cache_new(void) {
  CacheFeature* cf = (CacheFeature*)calloc(1, sizeof(CacheFeature));
  cf->base.vt = &CACHE_VT;
  cf->name = strdup("cache");
  cf->active = true; // matches rust default (overridden by init from options)
  cf->add_opts = NULL;
  cf->options = voxgig_new_undef();
  cf->track = (CacheTrack*)calloc(1, sizeof(CacheTrack));
  cf->track->store = voxgig_new_map();
  cf->track->order = voxgig_new_list();
  return (Feature*)cf;
}
