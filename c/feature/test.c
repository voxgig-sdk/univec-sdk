// The offline `test` feature (mirrors feature/test.rs): an in-memory mock
// transport that serves entity CRUD from a fixture, so generated tests run
// with no live server. An optional `net` block wraps the mock with simulated
// network conditions (latency, first-N failures, connection errors, offline)
// — see make_netsim below.

#include "sdk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// THE MOCK HAS TO AGREE WITH THE MODEL.
//
// A point carrying `transform.res: `body.item`` describes an API that answers
// {"item": {...}}, and the response transform unwraps that key on the way
// back. Handing back the bare payload means the transform unwraps a property
// that is not there and the caller gets nothing — a mock that only ever
// simulates APIs whose responses happen to be unwrapped.
//
// univec's list op declares `body.data`, so every list returned zero items
// while the fixture plainly held two. Mirrors the go/ts/lua/php mocks, which
// already wrap; rust, c and zig were the three that did not.
static voxgig_value* envelope(Context* ctx, voxgig_value* data) {
  if (v_is_noval(data) || v_is_null(data)) {
    return data;
  }
  voxgig_value* tm = getp(ctx->point, "transform");
  const char* spec = get_str(tm, "res");
  if (NULL == spec) {
    return data;
  }
  // Rebuild whatever nesting the transform unwraps. Multi-segment on purpose:
  // GraphQL ops unwrap `body.data.<field>` (and `body.data.<field>.<entity>`
  // for mutation payloads), not just a single envelope property.
  size_t n = strlen(spec);
  if (n < 8 || 0 != strncmp(spec, "`body.", 6) || '`' != spec[n - 1]) {
    return data;
  }
  size_t inner_len = n - 7;
  if (0 == inner_len) {
    return data;
  }
  char* inner = (char*)malloc(inner_len + 1);
  memcpy(inner, spec + 6, inner_len);
  inner[inner_len] = '\0';
  // Innermost segment first, so walk back from the end, terminating each
  // segment in place as it is consumed. cmap copies the key.
  voxgig_value* out = data;
  size_t pos = inner_len;
  while (1) {
    size_t start = pos;
    while (start > 0 && '.' != inner[start - 1]) {
      start--;
    }
    inner[pos] = '\0';
    out = cmap(1, inner + start, out);
    if (0 == start) {
      break;
    }
    pos = start - 1;
  }
  free(inner);
  return out;
}

// respond builds a transport-shaped response the result pipeline understands.
static voxgig_value* respond(Context* ctx, int64_t status, voxgig_value* data) {
  return cmap(4, "status", v_num((double)status), "statusText", v_str("OK"), "json",
              json_thunk(envelope(ctx, data)), "body", v_str("not-used"));
}

// For single-entity ops (load, remove) with an empty explicit match, fall
// back to the id the entity client already knows from a prior create/load
// (in ctx.mtch / ctx.data).
static voxgig_value* resolve_match(Context* ctx, voxgig_value* explicit) {
  if (voxgig_size(explicit) > 0) {
    return explicit;
  }
  voxgig_value* srcs[2] = {ctx->mtch, ctx->data};
  for (int i = 0; i < 2; i++) {
    voxgig_value* v = getp(srcs[i], "id");
    if (!v_is_noval(v) && !v_is_null(v) && !v_str_eq(v, "__UNDEFINED__")) {
      return cmap(1, "id", v);
    }
  }
  return v_map();
}

static const char* test_entity_name(Context* ctx) {
  if (ctx->entity) return ctx->entity->vt->get_name(ctx->entity);
  return ctx->op->entity;
}

static bool point_terminal(voxgig_value* p) {
  voxgig_value* parts = getp(p, "parts");
  if (!voxgig_is_list(parts)) return false;
  voxgig_list* l = voxgig_as_list(parts);
  if (0 == l->len) return false;
  voxgig_value* last = l->items[l->len - 1];
  return voxgig_is_string(last) && '{' == voxgig_as_string(last)[0];
}

static size_t point_depth(voxgig_value* p) {
  voxgig_value* parts = getp(p, "parts");
  return voxgig_is_list(parts) ? voxgig_as_list(parts)->len : 0;
}

// The entity's own endpoint: a terminal `{param}` marks a record route, and
// among equals the shallower path wins (the same rule as make_point).
static voxgig_value* pick_point(voxgig_value* points) {
  if (!voxgig_is_list(points)) return NULL;
  voxgig_list* l = voxgig_as_list(points);
  if (0 == l->len) return NULL;
  voxgig_value* point = l->items[0];
  for (size_t i = 1; i < l->len; i++) {
    voxgig_value* cand = l->items[i];
    if (point_terminal(cand) != point_terminal(point)) {
      if (point_terminal(cand)) point = cand;
    } else if (point_depth(cand) < point_depth(point)) {
      point = cand;
    }
  }
  return point;
}

static voxgig_value* reqd_names(voxgig_value* point, const char* kind) {
  voxgig_value* args_path = getpath2(point, "args", kind);
  voxgig_value* reqd_args = voxgig_select(args_path, cmap(1, "reqd", v_bool(true)));
  voxgig_value* reqd_spec =
      clist(3, v_str("`$EACH`"), v_str(""), v_str("`$KEY.name`"));
  voxgig_value* reqd = voxgig_transform(reqd_args, reqd_spec, NULL);
  if (!voxgig_is_list(reqd)) reqd = v_list();
  return reqd;
}

static voxgig_value* build_args(Context* ctx, voxgig_value* args) {
  Operation* op = ctx->op;
  const char* opname = op->name;
  const char* entname = test_entity_name(ctx);

  const char* ppath[6] = {"entity", entname, "op", opname, "points", NULL};
  voxgig_value* points = getpath_c(ctx->config, ppath);
  voxgig_value* point = pick_point(points);

  // Path AND query: a path-only read misses a query-addressed record
  // (e.g. GET /result?trace_id=), which has no path param at all.
  voxgig_value* reqd_params = reqd_names(point, "params");
  voxgig_value* reqd_query = reqd_names(point, "query");

  voxgig_value* qand = v_list();
  voxgig_value* q = cmap(1, "`$AND`", qand);

  if (voxgig_is_map(args)) {
    voxgig_strvec keys = voxgig_keysof(args);
    for (size_t ki = 0; ki < keys.len; ki++) {
      const char* key = keys.data[ki];
      bool is_id = strcmp(key, "id") == 0;
      bool is_reqd = !voxgig_isempty(voxgig_select(reqd_params, v_str(key))) ||
                     !voxgig_isempty(voxgig_select(reqd_query, v_str(key)));

      if (is_id || is_reqd) {
        voxgig_value* v = param_util(ctx, v_str(key));
        voxgig_value* ka = getp(op->alias, key);

        voxgig_value* qor = clist(1, cmap(1, key, v));
        if (voxgig_is_string(ka)) {
          const char* kas = voxgig_as_string(ka);
          voxgig_list_push(voxgig_as_list(qor), cmap(1, kas, v));
        }

        voxgig_list_push(voxgig_as_list(qand), cmap(1, "`$OR`", qor));
      }
    }
    voxgig_strvec_free(&keys);
  }

  Control* c = ctx->ctrl;
  if (control_has_explain(c)) {
    setp(c->explain, "test", cmap(1, "query", v_share(q)));
  }

  return q;
}

static voxgig_value* test_fetch(voxgig_value* entity, Context* ctx, const char* fullurl,
                                voxgig_value* fetchdef, PNError** err) {
  (void)fullurl;
  (void)fetchdef;
  *err = NULL;

  Operation* op = ctx->op;
  voxgig_value* entmap = to_map(getp(entity, op->entity));
  if (!voxgig_is_map(entmap)) entmap = v_map();

  const char* opname = op->name;

  if (strcmp(opname, "load") == 0) {
    voxgig_value* m = resolve_match(ctx, ctx->reqmatch);
    voxgig_value* args = build_args(ctx, m);
    voxgig_value* found = voxgig_select(entmap, args);
    voxgig_value* ent = voxgig_getelem(found, v_int(0), NULL);
    if (v_is_noval(ent) || v_is_null(ent)) {
      voxgig_value* r = respond(ctx, 404, v_undef());
      setp(r, "statusText", v_str("Not found"));
      return r;
    }
    voxgig_delprop(ent, v_str("$KEY"));
    return respond(ctx, 200, voxgig_clone(ent));
  }

  if (strcmp(opname, "list") == 0) {
    voxgig_value* args = build_args(ctx, ctx->reqmatch);
    voxgig_value* found = voxgig_select(entmap, args);
    if (v_is_noval(found) || v_is_null(found)) {
      voxgig_value* r = respond(ctx, 404, v_undef());
      setp(r, "statusText", v_str("Not found"));
      return r;
    }
    if (voxgig_is_list(found)) {
      voxgig_list* l = voxgig_as_list(found);
      for (size_t i = 0; i < l->len; i++) {
        voxgig_delprop(l->items[i], v_str("$KEY"));
      }
    }
    return respond(ctx, 200, voxgig_clone(found));
  }

  if (strcmp(opname, "update") == 0) {
    // Match the existing entity by id only (or its alias); reqdata's new
    // field values would otherwise cause select to filter it out.
    voxgig_value* reqdata = ctx->reqdata;
    voxgig_value* update_match = v_map();
    if (voxgig_is_map(reqdata)) {
      voxgig_value* idv = getp(reqdata, "id");
      if (!v_is_noval(idv)) setp(update_match, "id", idv);
      voxgig_value* alias_id = getp(op->alias, "id");
      if (voxgig_is_string(alias_id)) {
        const char* aid = voxgig_as_string(alias_id);
        voxgig_value* av = getp(reqdata, aid);
        if (!v_is_noval(av)) setp(update_match, aid, av);
      }
    }
    if (voxgig_size(update_match) == 0) {
      update_match = resolve_match(ctx, v_map());
    }
    voxgig_value* args = build_args(ctx, update_match);
    voxgig_value* found = voxgig_select(entmap, args);
    voxgig_value* ent = voxgig_getelem(found, v_int(0), NULL);
    if (v_is_noval(ent) || v_is_null(ent)) {
      // update miss: 404, never another record
      voxgig_value* r = respond(ctx, 404, v_undef());
      setp(r, "statusText", v_str("Not found"));
      return r;
    }
    if (voxgig_is_map(ent) && voxgig_is_map(reqdata)) {
      ent = voxgig_merge(clist(2, v_share(ent), v_share(reqdata)), VOXGIG_MAXDEPTH);
    }
    voxgig_delprop(ent, v_str("$KEY"));
    return respond(ctx, 200, voxgig_clone(ent));
  }

  if (strcmp(opname, "remove") == 0) {
    voxgig_value* m = resolve_match(ctx, ctx->reqmatch);
    voxgig_value* args = build_args(ctx, m);
    voxgig_value* found = voxgig_select(entmap, args);
    voxgig_value* ent = voxgig_getelem(found, v_int(0), NULL);
    // Remove only the first matched entity; a miss succeeds as a no-op.
    if (voxgig_is_map(ent)) {
      voxgig_value* id = getp(ent, "id");
      voxgig_delprop(entmap, id);
    }
    return respond(ctx, 200, v_undef());
  }

  if (strcmp(opname, "create") == 0) {
    (void)build_args(ctx, ctx->reqdata);
    voxgig_value* id = param_util(ctx, v_str("id"));
    if (v_is_noval(id) || v_is_null(id)) {
      int64_t r0 = rand_int(0x10000);
      int64_t r1 = rand_int(0x10000);
      int64_t r2 = rand_int(0x10000);
      int64_t r3 = rand_int(0x10000);
      char buf[32];
      snprintf(buf, sizeof(buf), "%04x%04x%04x%04x", (unsigned)r0, (unsigned)r1,
               (unsigned)r2, (unsigned)r3);
      id = v_str(buf);
    }

    voxgig_value* ent = voxgig_clone(ctx->reqdata);
    if (voxgig_is_map(ent)) {
      setp(ent, "id", id);
      if (voxgig_is_string(id)) {
        setp(entmap, voxgig_as_string(id), ent);
      }
      voxgig_delprop(ent, v_str("$KEY"));
      return respond(ctx, 200, voxgig_clone(ent));
    }
    return respond(ctx, 200, ent);
  }

  voxgig_value* r = respond(ctx, 404, v_undef());
  setp(r, "statusText", v_str("Unknown operation"));
  return r;
}

// ---- transport wiring -----------------------------------------------------

typedef struct {
  voxgig_value* entity;
} TestState;

static voxgig_value* test_transport_fn(Fetcher* self, Context* ctx, const char* url,
                                       voxgig_value* fetchdef, PNError** err) {
  TestState* ts = (TestState*)self->state;
  return test_fetch(ts->entity, ctx, url, fetchdef, err);
}

// make_netsim: simulated network conditions over the mock transport. Latency
// (fixed or {min,max}), a budget of first-N failures (`failTimes` ->
// `failStatus`), first-N connection errors (`errorTimes`), or a hard
// `offline` outage. Counter-driven, so simulations are deterministic.
typedef struct {
  voxgig_value* net;
  Fetcher* inner;
  int64_t calls;
} TestNetsimState;

static int64_t test_pick_latency(voxgig_value* net) {
  voxgig_value* l = getp(net, "latency");
  if (v_is_noval(l) || v_is_null(l)) {
    return 0;
  }
  if (voxgig_is_map(l)) {
    int64_t min = fopt_int(l, "min", 0);
    int64_t max = fopt_int(l, "max", min);
    if (max <= min) {
      return min;
    }
    return min + ((max - min) >> 1);
  }
  int64_t v = fopt_int(net, "latency", 0);
  return v > 0 ? v : 0;
}

static voxgig_value* test_netsim_fn(Fetcher* self, Context* ctx, const char* url,
                                    voxgig_value* fetchdef, PNError** err) {
  TestNetsimState* st = (TestNetsimState*)self->state;
  voxgig_value* net = st->net;
  *err = NULL;

  int64_t call = ++st->calls;

  if (fopt_bool(net, "offline", false)) {
    fopt_sleep_call(net, test_pick_latency(net));
    char msg[640];
    snprintf(msg, sizeof(msg), "Simulated network offline (URL was: \"%s\")", url);
    *err = context_make_error(ctx, "netsim_offline", msg);
    return NULL;
  }
  if (call <= fopt_int(net, "errorTimes", 0)) {
    fopt_sleep_call(net, test_pick_latency(net));
    char msg[128];
    snprintf(msg, sizeof(msg), "Simulated connection error (call %lld)", (long long)call);
    *err = context_make_error(ctx, "netsim_conn", msg);
    return NULL;
  }
  if (call <= fopt_int(net, "failTimes", 0)) {
    fopt_sleep_call(net, test_pick_latency(net));
    int64_t status = fopt_int(net, "failStatus", 503);
    return cmap(5, "status", v_num((double)status), "statusText",
                v_str("Simulated Failure"), "body", v_str("not-used"), "json",
                json_thunk(v_undef()), "headers", v_map());
  }
  fopt_sleep_call(net, test_pick_latency(net));
  return st->inner->fn(st->inner, ctx, url, fetchdef, err);
}

// ---- fixture id normalisation (walk callback) -----------------------------

static voxgig_value* fix_ids(voxgig_value* key, voxgig_value* val, voxgig_value* parent,
                             voxgig_value* path, void* ud) {
  (void)parent;
  (void)ud;
  if (voxgig_size(path) == 2) {
    if (voxgig_is_map(val) && voxgig_is_string(key)) {
      setp(val, "id", v_str(voxgig_as_string(key)));
    }
  }
  return voxgig_retain(val);
}

// ---- feature vtable -------------------------------------------------------

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
} TestFeature;

static const char* test_name(Feature* f) { return ((TestFeature*)f)->name; }
static bool test_active(Feature* f) { return ((TestFeature*)f)->active; }
static voxgig_value* test_add_options(Feature* f) { return ((TestFeature*)f)->add_opts; }

static void test_init(Feature* f, Context* ctx, voxgig_value* options) {
  TestFeature* tf = (TestFeature*)f;
  tf->options = options;

  voxgig_value* entity = to_map(getp(options, "entity"));
  if (!voxgig_is_map(entity)) entity = v_map();

  if (ctx->client) {
    ctx->client->mode = strdup("test");
  }

  // Ensure entity ids are correct.
  voxgig_walk(entity, fix_ids, NULL, VOXGIG_MAXDEPTH, NULL);

  TestState* ts = (TestState*)calloc(1, sizeof(TestState));
  ts->entity = entity;
  Fetcher* test_fetcher = (Fetcher*)calloc(1, sizeof(Fetcher));
  test_fetcher->fn = test_transport_fn;
  test_fetcher->state = ts;

  // Optional network behaviour simulation over the mock transport. Enabled
  // per test via test_sdk({"net": ...}, ...). When `net` is absent the mock
  // behaves exactly as before (no wrapping).
  voxgig_value* net = to_map(getp(options, "net"));
  Utility* util = context_util(ctx);
  if (v_is_noval(net)) {
    util->fetcher = test_fetcher;
  } else {
    TestNetsimState* ns = (TestNetsimState*)calloc(1, sizeof(TestNetsimState));
    ns->net = net;
    ns->inner = test_fetcher;
    ns->calls = 0;
    Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
    wrapped->fn = test_netsim_fn;
    wrapped->state = ns;
    util->fetcher = wrapped;
  }
}

static void test_hook(Feature* f, const char* name, Context* ctx) {
  (void)f; (void)name; (void)ctx;
}

static const FeatureVT TEST_VT = {
  test_name, test_active, test_add_options, test_init, test_hook,
  NULL, // no activity tracking
};

Feature* feature_test_new(void) {
  TestFeature* tf = (TestFeature*)calloc(1, sizeof(TestFeature));
  tf->base.vt = &TEST_VT;
  tf->name = strdup("test");
  tf->active = true; // matches rust new()
  tf->add_opts = NULL;
  tf->options = voxgig_new_undef();
  return (Feature*)tf;
}
