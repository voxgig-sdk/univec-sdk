/* Primary-utility corpus driver — C port.
 *
 * Drives every `primary` section of the shared corpus (.sdk/test/test.json)
 * through this SDK's utilities, the way the ts reference harness does. The
 * hand-written primary_utility_test.c beside this file covers the same
 * utilities with directly-constructed contexts; that suite can drift from the
 * contract, this one cannot — the cases ARE the contract.
 *
 * The corpus entry shapes are ctx+out, ctx+match, ctx+mark+out, args+mark+out,
 * args+err and in+match. `mark` is a case label, not an assertion.
 */

#include "feature_harness.h" /* test_sdk + Fetcher helpers + ctest.h */
#include "runner.h"       /* normalize + deep_equal, shared with the struct corpus */
#include "voxgig_struct.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static voxgig_value* CORPUS = NULL;
static int NPASS = 0;
static int NFAIL = 0;

/* ---- corpus access ------------------------------------------------------ */

static voxgig_value* mget(voxgig_value* m, const char* k) {
  if (!voxgig_is_map(m)) return NULL;
  return voxgig_map_get(voxgig_as_map(m), k);
}

static voxgig_value* primary_root(void) {
  if (!CORPUS) CORPUS = voxgig_parse_json_file("../.sdk/test/test.json");
  voxgig_value* p = mget(CORPUS, "primary");
  return p ? p : v_map();
}

/* section(name) -> the `basic` node, which carries `set`. */
static voxgig_value* section_basic(const char* name) {
  voxgig_value* sec = mget(primary_root(), name);
  voxgig_value* basic = mget(sec, "basic");
  return basic ? basic : v_map();
}

/* A section may carry its own client setup at DEF.setup.a — makeSpec and
 * prepareAuth read defaults off the CLIENT, not off ctx.options, so those two
 * cannot be driven with the shared client. */
static voxgig_value* section_setup(const char* name) {
  voxgig_value* sec = mget(primary_root(), name);
  voxgig_value* def = mget(sec, "DEF");
  voxgig_value* setup = mget(def, "setup");
  voxgig_value* a = mget(setup, "a");
  return a;
}

/* ---- match machinery ---------------------------------------------------- */

static char* vstr(voxgig_value* v) {
  if (!v) return strdup("");
  char* s = voxgig_stringify(v, -1);
  return s ? s : strdup("");
}

static char* lower_dup(const char* s) {
  char* o = strdup(s ? s : "");
  for (char* p = o; *p; p++) *p = (char)tolower((unsigned char)*p);
  return o;
}

static bool is_nullish(voxgig_value* v) {
  return v == NULL || voxgig_is_undef(v) || voxgig_is_null(v);
}

static bool matchval(voxgig_value* check, voxgig_value* base) {
  voxgig_value* nc = normalize(check);
  voxgig_value* nb = normalize(base);
  bool eq = deep_equal(nc, nb);
  voxgig_release(nc);
  voxgig_release(nb);
  if (eq) return true;

  if (!check || !v_is_str(check)) return false;
  const char* c = voxgig_as_string(check);
  if (strcmp(c, "__UNDEF__") == 0) return is_nullish(base);
  if (strcmp(c, "__EXISTS__") == 0) return !is_nullish(base);

  char* bs = vstr(base);
  size_t cl = strlen(c);

  /* A /pattern/ is a regex over the stringified base. */
  if (2 <= cl && c[0] == '/' && c[cl - 1] == '/') {
    char* pat = (char*)malloc(cl - 1);
    memcpy(pat, c + 1, cl - 2);
    pat[cl - 2] = '\0';
    bool ok = voxgig_re_test(pat, bs);
    free(pat);
    free(bs);
    return ok;
  }

  /* Otherwise a case-insensitive substring, as the reference does. */
  char* lb = lower_dup(bs);
  char* lc = lower_dup(c);
  bool ok = strstr(lb, lc) != NULL;
  free(lb);
  free(lc);
  free(bs);
  return ok;
}

/* Walk the CHECK structure; every leaf must matchval at the same path in
 * base. A missing path in base reads as null, which only __UNDEF__ matches. */
static bool do_match(voxgig_value* check, voxgig_value* base,
                     const char* path, char** fail) {
  if (voxgig_is_map(check)) {
    voxgig_map* m = voxgig_as_map(check);
    for (size_t i = 0; i < m->len; i++) {
      const char* k = m->entries[i].key;
      char sub[512];
      snprintf(sub, sizeof(sub), "%s%s%s", path, path[0] ? "." : "", k);
      if (!do_match(m->entries[i].value, mget(base, k), sub, fail)) return false;
    }
    return true;
  }
  if (voxgig_is_list(check)) {
    voxgig_list* l = voxgig_as_list(check);
    for (size_t i = 0; i < l->len; i++) {
      char sub[512];
      snprintf(sub, sizeof(sub), "%s.%zu", path, i);
      voxgig_value* be = NULL;
      if (voxgig_is_list(base) && i < voxgig_as_list(base)->len) {
        be = voxgig_as_list(base)->items[i];
      }
      if (!do_match(l->items[i], be, sub, fail)) return false;
    }
    return true;
  }
  if (matchval(check, base)) return true;

  char* cs = vstr(check);
  char* bs = vstr(base);
  char buf[1024];
  snprintf(buf, sizeof(buf), "MATCH: %s: [%s] <=> [%s]", path, cs, bs);
  free(cs);
  free(bs);
  *fail = strdup(buf);
  return false;
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

/* The match reads the corpus map while the utilities mutate the live objects
 * hanging off the context, so without this every ctx.* assertion reads null. */
static void publish_ctx(voxgig_value* ctxmap, Context* ctx) {
  if (!voxgig_is_map(ctxmap)) return;
  if (ctx->spec) setp(ctxmap, "spec", spec_to_value(ctx->spec));
  if (ctx->result) setp(ctxmap, "result", result_to_value(ctx->result));
  if (ctx->response) setp(ctxmap, "response", v_str("__EXISTS__"));
}

/* ---- the section runner ------------------------------------------------- */

typedef voxgig_value* (*ctxfn)(Context* ctx, voxgig_value* args, char** err);
typedef voxgig_value* (*argfn)(voxgig_value* args, char** err);

static void record(const char* section, bool ok, const char* msg) {
  if (ok) {
    NPASS++;
  } else {
    NFAIL++;
    printf("PRIMARY-FAIL %s - %s\n", section, msg ? msg : "?");
  }
}

static voxgig_value* arg_at(voxgig_value* args, size_t i) {
  if (!voxgig_is_list(args)) return NULL;
  voxgig_list* l = voxgig_as_list(args);
  return i < l->len ? l->items[i] : NULL;
}

static void runset(const char* name, UnivecSDK* cl,
                        ctxfn cf, argfn af) {
  voxgig_value* basic = section_basic(name);
  voxgig_value* set = mget(basic, "set");
  if (!voxgig_is_list(set)) return;
  voxgig_list* sl = voxgig_as_list(set);

  for (size_t i = 0; i < sl->len; i++) {
    voxgig_value* entry = sl->items[i];
    if (!voxgig_is_map(entry)) continue;

    /* resolve_args, mirroring the ts runner. */
    voxgig_value* args = v_list();
    voxgig_value* ectx = mget(entry, "ctx");
    voxgig_value* eargs = mget(entry, "args");
    voxgig_value* ein = mget(entry, "in");
    if (ectx) {
      voxgig_list_push(voxgig_as_list(args), voxgig_clone(ectx));
    } else if (voxgig_is_list(eargs)) {
      voxgig_list* al = voxgig_as_list(eargs);
      for (size_t k = 0; k < al->len; k++) {
        voxgig_list_push(voxgig_as_list(args), voxgig_retain(al->items[k]));
      }
    } else if (ein) {
      voxgig_list_push(voxgig_as_list(args), voxgig_clone(ein));
    }

    /* ts's resolveArgs writes the live first arg back as entry.ctx so a
     * `match: {ctx: ...}` resolves for args-style entries too. */
    voxgig_value* first = arg_at(args, 0);
    if (voxgig_is_map(first)) setp(entry, "ctx", voxgig_retain(first));

    char* err = NULL;
    voxgig_value* got = NULL;
    if (cf) {
      Context* ctx = corpus_ctx(cl, first);
      got = cf(ctx, args, &err);
      publish_ctx(first, ctx);
    } else {
      got = af(args, &err);
    }

    voxgig_value* eerr = mget(entry, "err");
    if (eerr && !v_is_noval(eerr)) {
      /* The case expects a failure. */
      if (!err) {
        record(name, false, "expected an error, got none");
        continue;
      }
      voxgig_value* errv = v_str(err);
      bool ok = (voxgig_is_bool(eerr) && voxgig_as_bool(eerr)) || matchval(eerr, errv);
      if (!ok) {
        char* es = vstr(eerr);
        char buf[1024];
        snprintf(buf, sizeof(buf), "ERROR MATCH: [%s] <=> [%s]", es, err);
        free(es);
        record(name, false, buf);
        continue;
      }
      voxgig_value* emat = mget(entry, "match");
      if (voxgig_is_map(emat)) {
        /* ts hands do_match the ERROR OBJECT, so `match: {err: {message}}`
         * resolves; a bare string leaves err.message reading null. */
        voxgig_value* base = cmap(4, "in", ein ? voxgig_retain(ein) : v_undef(),
                                  "out", got ? voxgig_retain(got) : v_undef(),
                                  "ctx", voxgig_retain(mget(entry, "ctx")),
                                  "err", cmap(1, "message", v_str(err)));
        char* fail = NULL;
        if (!do_match(emat, base, "", &fail)) {
          record(name, false, fail);
          continue;
        }
      }
      record(name, true, NULL);
      continue;
    }

    if (err) {
      record(name, false, err);
      continue;
    }

    /* check_result: `match` first, then `out`. */
    bool matched = false;
    voxgig_value* emat = mget(entry, "match");
    if (voxgig_is_map(emat)) {
      voxgig_value* base = cmap(4, "in", ein ? voxgig_retain(ein) : v_undef(),
                                "args", voxgig_retain(args),
                                "out", got ? voxgig_retain(got) : v_undef(),
                                "ctx", voxgig_retain(mget(entry, "ctx")));
      char* fail = NULL;
      if (!do_match(emat, base, "", &fail)) {
        record(name, false, fail);
        continue;
      }
      matched = true;
    }

    voxgig_value* eout = mget(entry, "out");
    voxgig_value* expected = eout ? eout : v_null();
    voxgig_value* ne = normalize(expected);
    voxgig_value* ng = normalize(got);
    bool eq = deep_equal(ne, ng);
    voxgig_release(ne);
    voxgig_release(ng);
    if (!eq && !(matched && !eout)) {
      char* es = vstr(expected);
      char* gs = vstr(got);
      char buf[1024];
      snprintf(buf, sizeof(buf), "Expected: %s, got: %s", es, gs);
      free(es);
      free(gs);
      record(name, false, buf);
      continue;
    }
    record(name, true, NULL);
  }
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
static UnivecSDK* SHARED = NULL;

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

static UnivecSDK* client_for(const char* section) {
  voxgig_value* setup = section_setup(section);
  if (voxgig_is_map(setup)) return test_sdk(v_undef(), voxgig_clone(setup));
  return SHARED;
}

int main(void) {
  SHARED = test_sdk(v_undef(), v_undef());

  runset("done", SHARED, s_done, NULL);
  runset("makeUrl", SHARED, s_make_url, NULL);
  runset("makeRequest", SHARED, s_make_request, NULL);
  runset("makeResponse", SHARED, s_make_response, NULL);
  runset("makeSpec", client_for("makeSpec"), s_make_spec, NULL);
  runset("prepareAuth", client_for("prepareAuth"), s_prepare_auth, NULL);
  runset("prepareBody", SHARED, s_prepare_body, NULL);
  runset("prepareHeaders", SHARED, s_prepare_headers, NULL);
  runset("prepareMethod", SHARED, s_prepare_method, NULL);
  runset("prepareParams", SHARED, s_prepare_params, NULL);
  runset("preparePath", SHARED, s_prepare_path, NULL);
  runset("prepareQuery", SHARED, s_prepare_query, NULL);
  runset("resultBasic", SHARED, s_result_basic, NULL);
  runset("resultBody", SHARED, s_result_body, NULL);
  runset("resultHeaders", SHARED, s_result_headers, NULL);
  runset("transformRequest", SHARED, s_transform_request, NULL);
  runset("transformResponse", SHARED, s_transform_response, NULL);
  runset("param", SHARED, s_param, NULL);
  runset("makeError", SHARED, s_make_error, NULL);
  runset("makeContext", SHARED, NULL, s_make_context);
  runset("makeOptions", SHARED, NULL, s_make_options);
  runset("operator", SHARED, NULL, s_operator);

  printf("\nPRIMARY CORPUS: PASS %d  FAIL %d\n", NPASS, NFAIL);
  return NFAIL == 0 ? 0 : 1;
}
