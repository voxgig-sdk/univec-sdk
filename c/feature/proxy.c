// Outbound HTTP(S) proxy support (mirrors feature/proxy.rs). Wraps the active
// transport and annotates each request's fetch definition with the proxy
// target (`fetchdef.proxy`). The default transport honours the annotation by
// routing the request through an agent configured with that proxy; custom
// transports can do the same. The proxy target comes from options (`url`) or,
// when `fromEnv` is set, the standard HTTPS_PROXY / HTTP_PROXY / NO_PROXY
// environment variables. Hosts matching `noProxy` bypass the proxy.

#include "sdk.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  // Activity tracking (mirrors the ts client._proxy record).
  int64_t routed;
  char* url; // "" when none
  char** no_proxy;
  size_t no_proxy_len;
} ProxyTrack;

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  ProxyTrack* track;
} ProxyFeature;

typedef struct {
  Fetcher* inner;
  ProxyTrack* track;
} ProxyState;

// The first non-empty environment variable value among names, else "".
// Returns a malloc'd string.
static char* first_env(const char** names, size_t n) {
  for (size_t i = 0; i < n; i++) {
    const char* v = getenv(names[i]);
    if (v && v[0] != '\0') return strdup(v);
  }
  return strdup("");
}

static char* trim_dup(const char* s) {
  while (*s && isspace((unsigned char)*s)) s++;
  const char* end = s + strlen(s);
  while (end > s && isspace((unsigned char)*(end - 1))) end--;
  size_t len = (size_t)(end - s);
  char* out = (char*)malloc(len + 1);
  memcpy(out, s, len);
  out[len] = '\0';
  return out;
}

// Split a string on ',' (no trimming; rust trims later). Returns a malloc'd
// array of malloc'd strings; *out_len set to the count (>= 1).
static char** split_commas(const char* s, size_t* out_len) {
  size_t count = 1;
  for (const char* p = s; *p; p++) {
    if (*p == ',') count++;
  }
  char** arr = (char**)malloc(sizeof(char*) * count);
  size_t n = 0;
  const char* start = s;
  while (1) {
    const char* comma = strchr(start, ',');
    size_t seglen = comma ? (size_t)(comma - start) : strlen(start);
    char* seg = (char*)malloc(seglen + 1);
    memcpy(seg, start, seglen);
    seg[seglen] = '\0';
    arr[n++] = seg;
    if (!comma) break;
    start = comma + 1;
  }
  *out_len = n;
  return arr;
}

// <scheme>://<host>[:port][/...]  — returns a malloc'd host string.
static char* host_of(const char* url) {
  const char* rest = url;
  const char* p = strstr(url, "://");
  if (p) rest = p + 3;
  size_t end = 0;
  while (rest[end] && rest[end] != '/' && rest[end] != ':') end++;
  char* host = (char*)malloc(end + 1);
  memcpy(host, rest, end);
  host[end] = '\0';
  return host;
}

static bool bypass(char** no_proxy, size_t n, const char* url) {
  if (n == 0) return false;
  char* host = host_of(url);
  bool result = false;
  for (size_t i = 0; i < n; i++) {
    const char* np = no_proxy[i];
    if (strcmp(np, "*") == 0) { result = true; break; }
    const char* np_trim = np;
    while (*np_trim == '.') np_trim++;
    if (strcmp(host, np) == 0) { result = true; break; }
    // host.ends_with(".{np_trim}")
    size_t hlen = strlen(host);
    size_t suffixlen = strlen(np_trim) + 1; // leading '.'
    if (hlen >= suffixlen) {
      const char* hend = host + (hlen - suffixlen);
      if (hend[0] == '.' && strcmp(hend + 1, np_trim) == 0) { result = true; break; }
    }
  }
  free(host);
  return result;
}

// Annotate fetchdef with the proxy address, unless there is no proxy or the
// host is bypassed. Returns fetchdef unchanged in those cases.
static voxgig_value* route(ProxyTrack* track, const char* url, voxgig_value* fetchdef) {
  const char* proxy_url = track->url;
  if (proxy_url == NULL || proxy_url[0] == '\0' || bypass(track->no_proxy, track->no_proxy_len, url)) {
    return fetchdef;
  }

  voxgig_value* out = voxgig_new_map();
  if (voxgig_is_map(fetchdef)) {
    voxgig_map* m = voxgig_as_map(fetchdef);
    for (size_t i = 0; i < m->len; i++) {
      setp(out, m->entries[i].key, m->entries[i].value);
    }
  }
  setp(out, "proxy", v_str(proxy_url));

  track->routed += 1;
  return out;
}

static voxgig_value* proxy_fetch(Fetcher* self, Context* ctx, const char* url,
                                 voxgig_value* fetchdef, PNError** err) {
  ProxyState* st = (ProxyState*)self->state;
  voxgig_value* routed = route(st->track, url, fetchdef);
  return st->inner->fn(st->inner, ctx, url, routed, err);
}

static const char* proxy_name(Feature* f) { return ((ProxyFeature*)f)->name; }
static bool proxy_active(Feature* f) { return ((ProxyFeature*)f)->active; }
static voxgig_value* proxy_add_options(Feature* f) { return ((ProxyFeature*)f)->add_opts; }

static void proxy_init(Feature* f, Context* ctx, voxgig_value* options) {
  ProxyFeature* pf = (ProxyFeature*)f;
  pf->options = options;
  pf->active = fopt_bool(options, "active", false);
  if (!pf->active) return;

  char* url = strdup(fopt_str(options, "url", ""));

  // rust: fopt_str_list returns None when "noProxy" is not a list.
  bool present = false;
  char** raw = NULL;
  size_t raw_len = 0;
  {
    voxgig_value* v = getp(options, "noProxy");
    if (voxgig_is_list(v)) {
      present = true;
      voxgig_list* l = voxgig_as_list(v);
      raw = (char**)malloc(sizeof(char*) * (l->len > 0 ? l->len : 1));
      for (size_t i = 0; i < l->len; i++) {
        if (voxgig_is_string(l->items[i])) {
          raw[raw_len++] = strdup(voxgig_as_string(l->items[i]));
        }
      }
    }
  }

  if (fopt_bool(options, "fromEnv", false)) {
    if (url[0] == '\0') {
      free(url);
      const char* names[] = {"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"};
      url = first_env(names, 4);
    }
    if (!present) {
      const char* names[] = {"NO_PROXY", "no_proxy"};
      char* np = first_env(names, 2);
      if (np[0] != '\0') {
        present = true;
        raw = split_commas(np, &raw_len);
      }
      free(np);
    }
  }
  (void)present;

  // Final noProxy = trim each and drop empties.
  char** final_np = (char**)malloc(sizeof(char*) * (raw_len > 0 ? raw_len : 1));
  size_t final_len = 0;
  for (size_t i = 0; i < raw_len; i++) {
    char* t = trim_dup(raw[i]);
    if (t[0] != '\0') {
      final_np[final_len++] = t;
    } else {
      free(t);
    }
    free(raw[i]);
  }
  free(raw);

  pf->track->url = url;
  pf->track->no_proxy = final_np;
  pf->track->no_proxy_len = final_len;

  Utility* util = context_util(ctx);
  ProxyState* st = (ProxyState*)calloc(1, sizeof(ProxyState));
  st->inner = util->fetcher;
  st->track = pf->track;

  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  wrapped->fn = proxy_fetch;
  wrapped->state = st;
  util->fetcher = wrapped;
}

static void proxy_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static voxgig_value* proxy_track(Feature* f) {
  ProxyTrack* t = ((ProxyFeature*)f)->track;
  return cmap(1, "routed", v_num((double)t->routed));
}

static const FeatureVT PROXY_VT = {
  proxy_name, proxy_active, proxy_add_options, proxy_init, proxy_hook,
  proxy_track,
};

Feature* feature_proxy_new(void) {
  ProxyFeature* pf = (ProxyFeature*)calloc(1, sizeof(ProxyFeature));
  pf->base.vt = &PROXY_VT;
  pf->name = strdup("proxy");
  pf->active = true; // matches rust new() (overridden by init from options)
  pf->add_opts = NULL;
  pf->options = voxgig_new_undef();
  pf->track = (ProxyTrack*)calloc(1, sizeof(ProxyTrack));
  pf->track->routed = 0;
  pf->track->url = strdup("");
  pf->track->no_proxy = NULL;
  pf->track->no_proxy_len = 0;
  return (Feature*)pf;
}
