// Client tracking (mirrors feature/clienttrack.rs). Establishes a stable
// per-client session id at construction and stamps identifying headers on
// every request: a `User-Agent` (`<clientName>/<clientVersion>`), an
// `X-Client-Id` (session), and a fresh per-request `X-Request-Id`. Header
// names, client name/version and the id generator (`idgen`) are configurable;
// caller-provided User-Agent / X-Client-Id values are never clobbered.

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;

  // Activity tracking (mirrors the ts client._clienttrack record).
  char* session;
  int64_t requests;
  char* last_request_id;
  char* client_name;
} ClienttrackFeature;

static char* ct_full_name(ClienttrackFeature* cf) {
  const char* name = fopt_str(cf->options, "clientName", "Univec-SDK");
  const char* version = fopt_str(cf->options, "clientVersion", "0.0.1");
  size_t n = strlen(name) + 1 + strlen(version) + 1;
  char* s = (char*)malloc(n);
  snprintf(s, n, "%s/%s", name, version);
  return s;
}

static char* ct_genid(ClienttrackFeature* cf, const char* kind) {
  voxgig_value* idgen = getp(cf->options, "idgen");
  if (voxgig_is_func(idgen)) {
    voxgig_value* r = call_vfn(idgen, v_str(kind));
    if (voxgig_is_string(r)) {
      return strdup(voxgig_as_string(r));
    }
  }
  char buf[64];
  snprintf(buf, sizeof(buf), "%c-%06llx%06llx%06llx",
           kind[0],
           (unsigned long long)rand_int(0x1000000),
           (unsigned long long)rand_int(0x1000000),
           (unsigned long long)rand_int(0x1000000));
  if (strlen(buf) > 20) buf[20] = '\0';
  return strdup(buf);
}

static void ct_post_construct(ClienttrackFeature* cf, Context* ctx) {
  (void)ctx;
  if (!cf->active) {
    return;
  }
  const char* sid = fopt_str(cf->options, "sessionId", "");
  cf->session = (sid[0] == '\0') ? ct_genid(cf, "session") : strdup(sid);
  cf->client_name = ct_full_name(cf);
}

static void ct_pre_request(ClienttrackFeature* cf, Context* ctx) {
  if (!cf->active) {
    return;
  }

  Spec* spec = ctx->spec;
  if (!spec) {
    return;
  }
  voxgig_value* headers = spec->headers;
  if (!voxgig_is_map(headers)) {
    voxgig_value* nh = v_map();
    spec->headers = nh;
    headers = nh;
  }

  // Lazily establish the session when PostConstruct never fired.
  if (cf->session == NULL || cf->session[0] == '\0') {
    const char* sid = fopt_str(cf->options, "sessionId", "");
    cf->session = (sid[0] == '\0') ? ct_genid(cf, "session") : strdup(sid);
  }

  voxgig_value* h = fopt_map(cf->options, "headers");
  cf->requests += 1;
  char* request_id = ct_genid(cf, "request");

  char* full = ct_full_name(cf);
  fheader_set_default(headers, fopt_str(h, "agent", "User-Agent"), full);
  fheader_set_default(headers, fopt_str(h, "client", "X-Client-Id"), cf->session);
  setp(headers, fopt_str(h, "request", "X-Request-Id"), v_str(request_id));

  cf->last_request_id = request_id;
  cf->client_name = ct_full_name(cf);
}

static const char* ct_name(Feature* f) { return ((ClienttrackFeature*)f)->name; }
static bool ct_active(Feature* f) { return ((ClienttrackFeature*)f)->active; }
static voxgig_value* ct_add_options(Feature* f) { return ((ClienttrackFeature*)f)->add_opts; }

static void ct_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)ctx;
  ClienttrackFeature* cf = (ClienttrackFeature*)f;
  cf->options = options;
  cf->active = fopt_bool(options, "active", false);
  cf->requests = 0;
}

static void ct_hook(Feature* f, const char* name, Context* ctx) {
  ClienttrackFeature* cf = (ClienttrackFeature*)f;
  if (strcmp(name, "PostConstruct") == 0) {
    ct_post_construct(cf, ctx);
  } else if (strcmp(name, "PreRequest") == 0) {
    ct_pre_request(cf, ctx);
  }
}

static voxgig_value* ct_track(Feature* f) {
  ClienttrackFeature* cf = (ClienttrackFeature*)f;
  return cmap(2, "requests", v_num((double)cf->requests),
              "session", v_str(cf->session ? cf->session : ""));
}

static const FeatureVT CLIENTTRACK_VT = {
  ct_name, ct_active, ct_add_options, ct_init, ct_hook,
  ct_track,
};

Feature* feature_clienttrack_new(void) {
  ClienttrackFeature* cf = (ClienttrackFeature*)calloc(1, sizeof(ClienttrackFeature));
  cf->base.vt = &CLIENTTRACK_VT;
  cf->name = strdup("clienttrack");
  cf->active = true;
  cf->add_opts = NULL;
  cf->options = voxgig_new_undef();
  cf->session = strdup("");
  cf->requests = 0;
  cf->last_request_id = strdup("");
  cf->client_name = strdup("");
  return (Feature*)cf;
}
