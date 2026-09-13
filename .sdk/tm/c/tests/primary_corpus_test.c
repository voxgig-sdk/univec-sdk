/* Primary-utility corpus driver — C port, on the VENDORED @voxgig/omni
 * runner (tests/vendor/omni, driven through tests/omni_resolver.h).
 *
 * Drives the `primary` sections of the shared corpus (.sdk/test/test.json)
 * through this SDK's utilities. The hand-written primary_utility_test.c
 * beside this file covers the same utilities with directly-constructed
 * contexts; that suite can drift from the contract, this one cannot — the
 * cases ARE the contract.
 *
 * The corpus entry shapes are ctx+out, ctx+match, ctx+mark+out,
 * args+mark+out, args+err and in+match. `mark` is a case label, not an
 * assertion. omni resolves the arguments, calls the subject, and checks
 * `out` / `match` / `err`; the second inline copy of the match engine this
 * file used to carry (matchval + do_match) is retired along with
 * tests/runner.h.
 *
 * CONTEXTS STAY MAPS ACROSS THE RUNNER (java's decision 1, omni#56). omni
 * sets `entry.ctx` to the args[0] map and a `match: {ctx: ...}` assertion
 * reads THROUGH it with omni's own getpath, which walks JSON values only.
 * A typed Context there would make every ctx assertion read "absent". So
 * the subject receives the MAP, builds the typed Context with corpus_ctx()
 * at the call site, runs the utility, and writes the observable ctx state
 * back into the very same omni map with publish_ctx() — which is what
 * makes `match: {ctx: {spec: {step: "reqform"}}}` resolve.
 *
 * NOT YET DRIVEN (the corpus carries them; no subject here yet): check,
 * clean, featureAdd, featureHook, featureInit, fetcher, makeFetchDef,
 * makePoint, makeResult.
 */

#include "feature_harness.h" /* test_sdk + Fetcher helpers + ctest.h */
#include "omni_resolver.h"   /* vendored omni + the voxgig<->omni bridge */
#include "voxgig_struct.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The shared corpus, compiled by the project build. Relative to the target
 * root, which is where the Makefile runs each test binary from. */
#define TEST_JSON_FILE "../.sdk/test/test.json"

static omni_pool* POOL = NULL;
static omni_runner* RUNNER = NULL;

/* Section scoreboard. omni stops a set at its FIRST failing entry, so a
 * row is pass/fail plus the number of cases the section HOLDS — the count
 * that proves the corpus still runs. */
typedef struct prow {
  char* name;
  size_t cases;
  int failed;
  char* err;
} prow;

static prow ROWS[64];
static size_t NROWS = 0;

static void row_add(const char* name, size_t cases, int failed, const char* err) {
  if (NROWS >= sizeof(ROWS) / sizeof(ROWS[0])) {
    return;
  }
  ROWS[NROWS].name = strdup(name);
  ROWS[NROWS].cases = cases;
  ROWS[NROWS].failed = failed;
  ROWS[NROWS].err = err ? strdup(err) : NULL;
  NROWS++;
}

/* ---- corpus access ------------------------------------------------------ */

static voxgig_value* mget(voxgig_value* m, const char* k) {
  if (!voxgig_is_map(m)) return NULL;
  return voxgig_map_get(voxgig_as_map(m), k);
}

static char* lower_dup(const char* s) {
  char* o = strdup(s ? s : "");
  for (char* p = o; *p; p++) *p = (char)tolower((unsigned char)*p);
  return o;
}

static voxgig_value* arg_at(voxgig_value* args, size_t i) {
  if (!voxgig_is_list(args)) return NULL;
  voxgig_list* l = voxgig_as_list(args);
  return i < l->len ? l->items[i] : NULL;
}

/* ---- live context from a corpus map ------------------------------------- */

static voxgig_value* corpus_json_thunk(void* ud, voxgig_value* args) {
  (void)args;
  return ud ? (voxgig_value*)ud : v_undef();
}

static Context* corpus_ctx(UnivecSDK* cl, voxgig_value* ctxmap) {
  CtxSpec cs;
  memset(&cs, 0, sizeof(cs));
  /* Only when the corpus names one: defaulting to "load" made the SDK report
   * the wrong operation in the error messages the corpus matches on. */
  voxgig_value* opn = mget(ctxmap, "opname");
  if (opn && v_is_str(opn)) cs.opname = voxgig_as_string(opn);
  cs.client = cl;
  cs.utility = sdk_get_utility(cl);
  Context* ctx = make_context_util(cs, sdk_get_root_ctx(cl));

  voxgig_value* sp = mget(ctxmap, "spec");
  if (voxgig_is_map(sp)) ctx->spec = spec_new(voxgig_clone(sp));

  voxgig_value* rs = mget(ctxmap, "result");
  if (voxgig_is_map(rs)) {
    ctx->result = result_new(voxgig_clone(rs));
    /* result_new does not carry an err, so a corpus result holding one
     * arrived empty and result_basic had no previous message to prepend. */
    voxgig_value* re = mget(rs, "err");
    voxgig_value* rm = mget(re, "message");
    if (rm && v_is_str(rm) && voxgig_as_string(rm)[0]) {
      ctx->result->err = pn_error_new("", voxgig_as_string(rm));
    }
  }

  voxgig_value* rp = mget(ctxmap, "response");
  if (voxgig_is_map(rp)) {
    ctx->response = response_new(voxgig_clone(rp));
    /* result_body reads response.json and requires it to be CALLABLE; the
     * corpus supplies a plain `body`. */
    voxgig_value* body = mget(rp, "body");
    if (body && !v_is_noval(body)) {
      ctx->response->body = voxgig_retain(body);
      ctx->response->json = vfn(corpus_json_thunk, voxgig_retain(body));
    }
    /* Header names arrive from the wire in any case; the contract is
     * lowercase and result_headers copies them verbatim. */
    voxgig_value* hs = mget(rp, "headers");
    if (voxgig_is_map(hs)) {
      voxgig_map* hm = voxgig_as_map(hs);
      voxgig_value* low = v_map();
      for (size_t i = 0; i < hm->len; i++) {
        char* lk = lower_dup(hm->entries[i].key);
        setp(low, lk, voxgig_retain(hm->entries[i].value));
        free(lk);
      }
      ctx->response->headers = low;
    }
  }

  voxgig_value* pt = mget(ctxmap, "point");
  if (voxgig_is_map(pt)) ctx->point = voxgig_clone(pt);
  voxgig_value* rd = mget(ctxmap, "reqdata");
  if (rd && !v_is_noval(rd)) ctx->reqdata = voxgig_retain(rd);
  voxgig_value* rmt = mget(ctxmap, "reqmatch");
  if (rmt && !v_is_noval(rmt)) ctx->reqmatch = voxgig_retain(rmt);
  voxgig_value* dt = mget(ctxmap, "data");
  if (dt && !v_is_noval(dt)) ctx->data = voxgig_retain(dt);
  voxgig_value* mt = mget(ctxmap, "match");
  if (mt && !v_is_noval(mt)) ctx->mtch = voxgig_retain(mt);
  voxgig_value* op = mget(ctxmap, "options");
  if (voxgig_is_map(op)) ctx->options = voxgig_clone(op);
  voxgig_value* cf = mget(ctxmap, "config");
  if (voxgig_is_map(cf)) ctx->config = voxgig_clone(cf);
  return ctx;
}

/* Write the OBSERVABLE state of the typed context back into the omni ctx
 * map the entry holds, which is where a `match: {ctx: ...}` assertion
 * reads. The subject mutated the typed context; the map is what the runner
 * can walk. */
static void publish_ctx(omni_pool* pool, omni_json* ctxmap, Context* ctx) {
  if (NULL == ctx || !omni_ismap(ctxmap)) return;
  if (ctx->spec) omni_map_set(ctxmap, "spec", omnivx_tomni(pool, spec_to_value(ctx->spec)));
  if (ctx->result) omni_map_set(ctxmap, "result", omnivx_tomni(pool, result_to_value(ctx->result)));
  if (ctx->response) omni_map_set(ctxmap, "response", omni_str(pool, OMNI_EXISTSMARK));
}

/* ---- the section runner ------------------------------------------------- */

typedef voxgig_value* (*ctxfn)(Context* ctx, voxgig_value* args, char** err);
typedef voxgig_value* (*argfn)(voxgig_value* args, char** err);

typedef struct psubj {
  ctxfn cf;
  argfn af;
  UnivecSDK* cl;
} psubj;

/* The omni subject: omni values in, omni value (or error message) out. */
static omni_result primary_call(omni_pool* pool, omni_json** args, size_t nargs, void* ud) {
  psubj* p = (psubj*)ud;
  omni_result out;
  voxgig_value* vargs = v_list();
  voxgig_value* got = NULL;
  char* err = NULL;
  size_t i;

  out.val = NULL;
  out.err = NULL;

  for (i = 0; i < nargs; i++) {
    voxgig_list_push(voxgig_as_list(vargs), omnivx_tovx(args[i]));
  }

  if (p->cf) {
    voxgig_value* first = arg_at(vargs, 0);
    Context* ctx = corpus_ctx(p->cl, first);
    got = p->cf(ctx, vargs, &err);
    if (0 < nargs) publish_ctx(pool, args[0], ctx);
  } else {
    got = p->af(vargs, &err);
  }

  if (NULL != err) {
    out.err = omni_pool_strdup(pool, err);
    free(err);
    return out;
  }

  out.val = omnivx_tomni(pool, got);
  return out;
}

/* A section may carry its own client setup at DEF.setup.a — makeSpec and
 * prepareAuth read defaults off the CLIENT, not off ctx.options, so those
 * two cannot be driven with the shared client. */
static UnivecSDK* SHARED = NULL;

static UnivecSDK* client_for(omni_json* spec) {
  omni_json* setup = omni_map_get(omni_map_get(omni_map_get(spec, "DEF"), "setup"), "a");
  if (omni_ismap(setup)) {
    return test_sdk(v_undef(), omnivx_tovx(setup));
  }
  return SHARED;
}

/* Resolve `primary.<name>.basic` and run it. An ABSENT section, or one
 * with no entries, is a FAILURE: a section that runs no case proves
 * nothing. */
static void runset(const char* name, ctxfn cf, argfn af) {
  omni_runpack* pack;
  omni_json* basic;
  size_t cases;
  char* err = NULL;
  int failed;
  psubj* p;

  pack = omni_runner_run(RUNNER, name, NULL, &err);
  if (NULL == pack || !omni_ismap(omni_spec(pack))) {
    row_add(name, 0, 1, "corpus section missing - check .sdk/test/primary/");
    return;
  }

  basic = omni_set(pack, "basic");
  if (!omni_ismap(basic)) {
    row_add(name, 0, 1, "corpus section has no `basic` group");
    return;
  }

  cases = omnivx_setsize(basic);
  if (0 == cases) {
    row_add(name, 0, 1, "corpus section is EMPTY - zero cases would run");
    return;
  }

  p = (psubj*)omni_pool_alloc(POOL, sizeof(psubj));
  p->cf = cf;
  p->af = af;
  p->cl = client_for(omni_spec(pack));

  failed = omni_runsetflags(pack, basic, omnivx_flags(1, name),
                            omnivx_rawsubject(POOL, primary_call, p), &err);
  row_add(name, cases, failed, err);
}

/* ---- per-section subjects ----------------------------------------------- */

#define ERRSET(e, p) do { if (p) { *(e) = strdup((p)->msg ? (p)->msg : "error"); } } while (0)

static voxgig_value* s_done(Context* c, voxgig_value* a, char** e) {
  (void)a;
  PNError* pe = NULL;
  voxgig_value* r = done_util(c, &pe);
  ERRSET(e, pe);
  return r;
}
static voxgig_value* s_make_url(Context* c, voxgig_value* a, char** e) {
  (void)a;
  PNError* pe = NULL;
  char* u = make_url_util(c, &pe);
  ERRSET(e, pe);
  return u ? v_str(u) : v_undef();
}
static voxgig_value* s_make_request(Context* c, voxgig_value* a, char** e) {
  (void)a;
  PNError* pe = NULL;
  make_request_util(c, &pe);
  ERRSET(e, pe);
  return c->result ? result_to_value(c->result) : v_undef();
}
static voxgig_value* s_make_response(Context* c, voxgig_value* a, char** e) {
  (void)a;
  PNError* pe = NULL;
  make_response_util(c, &pe);
  ERRSET(e, pe);
  return c->result ? result_to_value(c->result) : v_undef();
}
static voxgig_value* s_make_spec(Context* c, voxgig_value* a, char** e) {
  (void)a;
  PNError* pe = NULL;
  Spec* s = make_spec_util(c, &pe);
  ERRSET(e, pe);
  if (s) c->spec = s;
  return s ? spec_to_value(s) : v_undef();
}
static voxgig_value* s_prepare_auth(Context* c, voxgig_value* a, char** e) {
  (void)a;
  PNError* pe = NULL;
  prepare_auth_util(c, &pe);
  ERRSET(e, pe);
  return c->spec ? spec_to_value(c->spec) : v_undef();
}
static voxgig_value* s_prepare_body(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  return prepare_body_util(c);
}
static voxgig_value* s_prepare_headers(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  return prepare_headers_util(c);
}
static voxgig_value* s_prepare_method(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  const char* m = prepare_method_util(c);
  return (m && m[0]) ? v_str(m) : v_undef();
}
static voxgig_value* s_prepare_params(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  return prepare_params_util(c);
}
static voxgig_value* s_prepare_path(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  char* p = prepare_path_util(c);
  return p ? v_str(p) : v_undef();
}
static voxgig_value* s_prepare_query(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  return prepare_query_util(c);
}
static voxgig_value* s_result_basic(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  SdkResult* r = result_basic_util(c);
  if (r) c->result = r;
  return c->result ? result_to_value(c->result) : v_undef();
}
static voxgig_value* s_result_body(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  SdkResult* r = result_body_util(c);
  if (r) c->result = r;
  return c->result ? result_to_value(c->result) : v_undef();
}
static voxgig_value* s_result_headers(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  SdkResult* r = result_headers_util(c);
  if (r) c->result = r;
  return c->result ? result_to_value(c->result) : v_undef();
}
static voxgig_value* s_transform_request(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  return transform_request_util(c);
}
static voxgig_value* s_transform_response(Context* c, voxgig_value* a, char** e) {
  (void)a; (void)e;
  return transform_response_util(c);
}
static voxgig_value* s_param(Context* c, voxgig_value* a, char** e) {
  (void)e;
  return param_util(c, arg_at(a, 1));
}
static voxgig_value* s_make_error(Context* c, voxgig_value* a, char** e) {
  voxgig_value* a1 = arg_at(a, 1);
  voxgig_value* msgv = mget(a1, "message");
  PNError* in = NULL;
  if (msgv && v_is_str(msgv) && voxgig_as_string(msgv)[0]) {
    in = pn_error_new("", voxgig_as_string(msgv));
  }
  PNError* out = NULL;
  voxgig_value* r = make_error_util(c, in, &out);
  ERRSET(e, out);
  return r;
}

/* Sections that take a bare map rather than a ctx. */

static voxgig_value* s_make_context(voxgig_value* a, char** e) {
  (void)e;
  Context* c = corpus_ctx(SHARED, arg_at(a, 0));
  voxgig_value* op = v_map();
  if (c->op) {
    setp(op, "entity", v_str(c->op->entity ? c->op->entity : ""));
    setp(op, "name", v_str(c->op->name ? c->op->name : ""));
    setp(op, "input", v_str(c->op->input ? c->op->input : ""));
    setp(op, "points", c->op->points ? voxgig_retain(c->op->points) : v_list());
  }
  return cmap(1, "op", op);
}
static voxgig_value* s_make_options(voxgig_value* a, char** e) {
  (void)e;
  voxgig_value* in = arg_at(a, 0);
  Context* c = corpus_ctx(SHARED, v_map());
  voxgig_value* cf = mget(in, "config");
  if (cf) c->config = voxgig_retain(cf);
  voxgig_value* op = mget(in, "options");
  if (op) c->options = voxgig_retain(op);
  return make_options_util(c);
}
static voxgig_value* s_operator(voxgig_value* a, char** e) {
  (void)e;
  voxgig_value* in = arg_at(a, 0);
  voxgig_value* en = mget(in, "entity");
  voxgig_value* nm = mget(in, "name");
  voxgig_value* ip = mget(in, "input");
  voxgig_value* pts = mget(in, "points");
  return cmap(4,
              "entity", en ? voxgig_retain(en) : v_str("_"),
              "input", ip ? voxgig_retain(ip) : v_str("_"),
              "name", nm ? voxgig_retain(nm) : v_str("_"),
              "points", voxgig_is_list(pts) ? voxgig_retain(pts) : v_list());
}
/* ---- main --------------------------------------------------------------- */

int main(void) {
  char* err = NULL;
  size_t cases = 0;
  int failed = 0;
  size_t i;

  POOL = omni_pool_new();

  RUNNER = omni_make_runner(POOL, TEST_JSON_FILE, NULL, NULL, &err);
  if (NULL == RUNNER) {
    fprintf(stderr, "primary corpus: %s\n", NULL == err ? "cannot make runner" : err);
    return 1;
  }

  SHARED = test_sdk(v_undef(), v_undef());

  runset("done", s_done, NULL);
  runset("makeUrl", s_make_url, NULL);
  runset("makeRequest", s_make_request, NULL);
  runset("makeResponse", s_make_response, NULL);
  runset("makeSpec", s_make_spec, NULL);
  runset("prepareAuth", s_prepare_auth, NULL);
  runset("prepareBody", s_prepare_body, NULL);
  runset("prepareHeaders", s_prepare_headers, NULL);
  runset("prepareMethod", s_prepare_method, NULL);
  runset("prepareParams", s_prepare_params, NULL);
  runset("preparePath", s_prepare_path, NULL);
  runset("prepareQuery", s_prepare_query, NULL);
  runset("resultBasic", s_result_basic, NULL);
  runset("resultBody", s_result_body, NULL);
  runset("resultHeaders", s_result_headers, NULL);
  runset("transformRequest", s_transform_request, NULL);
  runset("transformResponse", s_transform_response, NULL);
  runset("param", s_param, NULL);
  runset("makeError", s_make_error, NULL);
  runset("makeContext", NULL, s_make_context);
  runset("makeOptions", NULL, s_make_options);
  runset("operator", NULL, s_operator);

  for (i = 0; i < NROWS; i++) {
    cases += ROWS[i].cases;
    failed += ROWS[i].failed ? 1 : 0;
    if (ROWS[i].failed) {
      printf("PRIMARY-FAIL %s - %s\n", ROWS[i].name,
             NULL == ROWS[i].err ? "(no message)" : ROWS[i].err);
    }
  }

  printf("\nPRIMARY CORPUS: %zu cases in %zu sections, %d section(s) FAILED\n", cases, NROWS,
         failed);

  for (i = 0; i < NROWS; i++) {
    free(ROWS[i].name);
    free(ROWS[i].err);
  }

  return 0 == failed ? 0 : 1;
}
