import type {
  ModelEntity
} from '@voxgig/apidef'

import {
  cmp,
  configDefinition,
  each,
  File,
  Content,
  entityCollection,
  targetFeatures,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'


import { cIdent, cVarName } from './utility_c'


// A custom action is not a vtable slot the sweep can call by name.
const CRUD = ['list', 'load', 'create', 'update', 'patch', 'remove']

const DIAGNOSTIC = ['log', 'debug', 'audit', 'telemetry', 'cost', 'metrics', 'clienttrack']


// The canary sweep (twin of TestClean_ts). C is statically typed, so the
// operation candidates the ts sweep finds by reflection are enumerated here
// at generation time, each with the path parameters its config points
// declare; the sweep still DRIVES them to find the first that completes.
const TestClean = cmp(function TestClean(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const Name = model.const.Name
  const ident = cIdent(model)

  const auth = {
    suppressed: isAuthSuppressed(model),
    where: resolveAuthIn(model),
    name: 'header' === resolveAuthIn(model)
      ? resolveAuthName(model).toLowerCase() : resolveAuthName(model),
    basic: isHttpBasicAuth(model),
  }

  const features = Object.keys(targetFeatures(model, target))
    .filter((name) => DIAGNOSTIC.includes(name))
    .sort()

  const configEntity = configDefinition(model, target.name).def.entity || {}

  const candidates: Candidate[] = []
  const entities = each(entityCollection(model)).filter((e: any) => false !== e.active)
  each(entities, (entity: ModelEntity) => {
    const evar = cVarName(entity.name)
    const ops = Object.keys((entity as any).op || {})
      .filter((op) => CRUD.includes(op))
      .sort((a, b) => CRUD.indexOf(a) - CRUD.indexOf(b))
    for (const op of ops) {
      candidates.push({
        name: entity.name + '.' + op, fn: 'drive_' + evar + '_' + op, evar, op,
        params: pointParams(configEntity[entity.name]?.op?.[op]),
      })
    }
  })

  File({ name: 'clean_test.c' }, () => {
    Content(render({ Name, ident, auth, features, candidates }))
  })
})


type Candidate = { name: string, fn: string, evar: string, op: string, params: string[] }


// Every path parameter an operation's points declare, as the generated
// config carries them (points[].args.params[].name).
function pointParams(opdef: any): string[] {
  const names: string[] = []
  for (const point of opdef?.points || []) {
    for (const p of point?.args?.params || []) {
      if ('string' === typeof p?.name && !names.includes(p.name)) names.push(p.name)
    }
  }
  return names
}


function render(spec: {
  Name: string,
  ident: string,
  auth: { suppressed: boolean, where: string, name: string, basic: boolean },
  features: string[],
  candidates: Candidate[],
}): string {
  const { Name, ident, auth, features, candidates } = spec

  const drivers = candidates.map((c) => 'list' === c.op
    ? `static PNError* ${c.fn}(${Name}SDK* sdk, voxgig_value* mtch, voxgig_value* ctrl, voxgig_value** out,
    voxgig_value** match) {
  PNError* err = NULL;
  Entity* e = ${ident}_${c.evar}(sdk, NULL);
  Entity** items = e->vt->list(e, mtch, ctrl, &err);
  if (match) *match = e->vt->matchv(e, NULL);
  if (err) return err;
  voxgig_value* list = v_list();
  for (size_t i = 0; items && items[i]; i++) {
    voxgig_list_push(voxgig_as_list(list), items[i]->vt->data(items[i], NULL));
  }
  *out = list;
  return NULL;
}
`
    : `static PNError* ${c.fn}(${Name}SDK* sdk, voxgig_value* mtch, voxgig_value* ctrl, voxgig_value** out,
    voxgig_value** match) {
  PNError* err = NULL;
  Entity* e = ${ident}_${c.evar}(sdk, NULL);
  Entity* r = e->vt->${c.op}(e, mtch, ctrl, &err);
  if (match) *match = e->vt->matchv(e, NULL);
  if (err) return err;
  *out = r ? r->vt->data(r, NULL) : v_undef();
  return NULL;
}
`).join('\n') + '\n' + candidates.map((c) =>
    `static voxgig_value* ${c.fn}_stream(${Name}SDK* sdk, voxgig_value* mtch, voxgig_value* callopts, PNError** err) {
  return ${c.evar}_stream(${ident}_${c.evar}(sdk, NULL), "${c.op}", mtch, callopts, err);
}
`).join('\n')

  const table = candidates.map((c) => `  { "${c.name}", ${c.fn}, ${c.fn}_stream, { ${
    c.params.map((p) => '"' + cstr(p) + '", ').join('')}NULL } },`).join('\n')

  return `// Generated canary sweep (see TestClean_c): no credential leaves the SDK
// in any form, and the sweep can see one when clean is switched off.

#include "ctest.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

// Generated: the credential's wire placement is fixed when the SDK is built.
static const bool AUTH_SUPPRESSED = ${auth.suppressed};
static const char* AUTH_WHERE = "${cstr(auth.where)}";
static const char* AUTH_NAME = "${cstr(auth.name)}";

// The diagnostic features this SDK ships.
static const char* FEATURES[] = { ${features.map((f) => '"' + f + '"').join(', ')}${0 < features.length ? ', ' : ''}NULL };

static const char* CANARY_APIKEY = "CANARY-APIKEY-k9x2m7q4p1";
static const char* CANARY_SECRET = "CANARY-SECRET-w3e8r5t2y6";
static const char* CANARY_HEADER = "CANARY-HEADER-z1x4c7v0b3";
static const char* CANARY_VALUE = "CANARY-VALUE-n5m8b2v9c4";

static const char* MASK = "[redacted]";

// The sweep's own encoders: a leak of an encoded form must not hide behind
// the SDK's encoder.
static char* b64(const char* in) {
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
  out[o] = '\\0';
  return out;
}

static char* pct(const char* in) {
  size_t n = strlen(in);
  char* out = (char*)malloc(n * 3 + 1);
  size_t o = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)in[i];
    if (isalnum(c) || strchr("-_.!~*'()", c)) {
      out[o++] = (char)c;
    } else {
      o += (size_t)sprintf(out + o, "%%%02X", c);
    }
  }
  out[o] = '\\0';
  return out;
}

// Every form a canary can travel in.
static const char* FORMS[16];
static size_t NFORMS = 0;

static void build_forms(void) {
  const char* canaries[4] = { CANARY_APIKEY, CANARY_SECRET, CANARY_HEADER, CANARY_VALUE };
  for (int i = 0; i < 4; i++) {
    FORMS[NFORMS++] = canaries[i];
    FORMS[NFORMS++] = b64(canaries[i]);
    FORMS[NFORMS++] = pct(canaries[i]);
  }
  char pair[256];
  snprintf(pair, sizeof(pair), "%s:%s", CANARY_APIKEY, CANARY_SECRET);
  FORMS[NFORMS++] = b64(pair);
}

typedef struct {
  const char* name;
  char* text;
} Sink;

static Sink* SINKS = NULL;
static size_t NSINKS = 0;
static size_t CAPSINKS = 0;

static void push(const char* name, char* text) {
  if (NSINKS == CAPSINKS) {
    CAPSINKS = CAPSINKS ? CAPSINKS * 2 : 64;
    SINKS = (Sink*)realloc(SINKS, CAPSINKS * sizeof(Sink));
  }
  SINKS[NSINKS].name = name;
  SINKS[NSINKS].text = text ? text : strdup("");
  NSINKS++;
}

static void push_value(const char* name, voxgig_value* val) {
  push(name, voxgig_jsonify(val, NULL));
  push(name, voxgig_stringify(val, -1));
}

static void push_error(const char* name, PNError* err) {
  push(name, strdup(err->msg ? err->msg : ""));
  push(name, pn_error_str(err));
  push(name, voxgig_jsonify(err->spec, NULL));
  push(name, voxgig_jsonify(err->result, NULL));
}

static voxgig_value* capture_fn(void* ud, voxgig_value* arg) {
  push_value((const char*)ud, arg);
  return v_undef();
}

// Captures the serialised context from inside the pipeline: what a hook
// author would hand to a logger.
typedef struct {
  Feature base;
} CaptureFeature;

static const char* capture_name(Feature* f) { (void)f; return "capture"; }
static bool capture_active(Feature* f) { (void)f; return true; }
static voxgig_value* capture_add_options(Feature* f) { (void)f; return NULL; }
static void capture_init(Feature* f, Context* ctx, voxgig_value* options) {
  (void)f; (void)ctx; (void)options;
}
static void capture_hook(Feature* f, const char* name, Context* ctx) {
  (void)f;
  if (0 == strcmp(name, "PreRequest") || 0 == strcmp(name, "PreResponse") ||
      0 == strcmp(name, "PreUnexpected")) {
    push("ctx", context_str(ctx));
    push_value("ctx", context_to_value(ctx));
  }
}

static const FeatureVT CAPTURE_VT = {
  capture_name, capture_active, capture_add_options, capture_init, capture_hook, NULL,
};

// A feature that fails the operation from inside the pipeline, quoting the
// request it saw. A C hook has no error return, so it fails the result: an
// error make_error receives from a hook, not from the pipeline. For the same
// reason there is no variant failing in PreUnexpected: make_error has built
// and cleaned the error it returns before that hook runs.
static const char* throw_name(Feature* f) { (void)f; return "throwhook"; }
static void throw_hook(Feature* f, const char* name, Context* ctx) {
  (void)f;
  if (0 != strcmp(name, "PreResponse") || !ctx->result) return;
  char* spec = voxgig_jsonify(ctx->spec ? spec_to_value(ctx->spec) : v_undef(), NULL);
  char msg[4096];
  snprintf(msg, sizeof(msg), "hook saw %s", spec ? spec : "");
  ctx->result->err = context_make_error(ctx, "hook", msg);
}

static const FeatureVT THROW_VT = {
  throw_name, capture_active, capture_add_options, capture_init, throw_hook, NULL,
};

// A feature that refuses the operation with the SDK's own error, as rbac
// does, whose code quotes a registered value; it records the error
// PreUnexpected hands a hook.
static const char* deny_name(Feature* f) { (void)f; return "denyhook"; }
static void deny_hook(Feature* f, const char* name, Context* ctx) {
  (void)f;
  if (0 == strcmp(name, "PrePoint")) {
    char code[128];
    snprintf(code, sizeof(code), "denied:%s", CANARY_VALUE);
    ctx_out_set_point_err(ctx, context_make_error(ctx, code, "denied"));
  } else if (0 == strcmp(name, "PreUnexpected") && ctx->ctrl && ctx->ctrl->err) {
    push_error("error", ctx->ctrl->err);
  }
}

static const FeatureVT DENY_VT = {
  deny_name, capture_active, capture_add_options, capture_init, deny_hook, NULL,
};

// A stream that succeeds, so the pipeline's terminal step never runs. A C
// stream producer has no error channel, so no stream fails.
static voxgig_value* streamok_items(void* ud) {
  voxgig_value* data = (voxgig_value*)ud;
  voxgig_value* out = v_list();
  if (voxgig_is_list(data)) {
    voxgig_list* l = voxgig_as_list(data);
    for (size_t i = 0; i < l->len; i++) {
      voxgig_list_push(voxgig_as_list(out), voxgig_retain(l->items[i]));
    }
  } else if (!v_is_noval(data) && !v_is_null(data)) {
    voxgig_list_push(voxgig_as_list(out), voxgig_retain(data));
  }
  return out;
}

static const char* streamok_name(Feature* f) { (void)f; return "streamok"; }
static void streamok_hook(Feature* f, const char* name, Context* ctx) {
  (void)f;
  if (0 != strcmp(name, "PreDone") || !ctx->result) return;
  ctx->result->stream = streamok_items;
  ctx->result->stream_ud = v_share(ctx->result->resdata);
}

static const FeatureVT STREAMOK_VT = {
  streamok_name, capture_active, capture_add_options, capture_init, streamok_hook, NULL,
};

enum { SC_OK = 0, SC_NOTFOUND, SC_SERVER, SC_TRANSPORT, SC_NOTJSON, SC_COUNT };
static const char* SC_NAMES[] = { "ok", "notfound", "server", "transport", "notjson" };

static voxgig_value* response(int status, voxgig_value* data, const char* hk, const char* hv) {
  voxgig_value* headers = cmap(1, "content-type", v_str("application/json"));
  if (hk) setp(headers, hk, v_str(hv));
  return cmap(5,
    "status", v_num((double)status),
    "statusText", v_str(status < 400 ? "OK" : "ERR"),
    "headers", headers,
    "body", v_str(voxgig_jsonify(data, NULL)),
    "json", json_thunk(data));
}

static voxgig_value* respond(int sc, const char* url) {
  switch (sc) {
    case SC_OK:
      return response(200, cmap(2, "id", v_str("i1"), "name", v_str("n1")),
                      "x-session-token", "RESP-TOKEN-a1b2c3d4e5");
    case SC_NOTFOUND:
      return response(404, cmap(1, "error", v_str("no such record")), NULL, NULL);
    case SC_SERVER:
      return response(500, cmap(1, "error", v_str("boom")), NULL, NULL);
    case SC_TRANSPORT: {
      char msg[2048];
      snprintf(msg, sizeof(msg), "socket hang up (URL was: \\"%s\\")", url);
      return cmap(1, "__err__", v_str(msg));
    }
    default:
      return cmap(5,
        "status", v_num(200),
        "statusText", v_str("OK"),
        "headers", v_map(),
        "body", v_str("<html>"),
        "json", json_thunk(v_undef()));
  }
}

// The transport seam: system.fetch is called with [url, fetchdef].
static voxgig_value* transport_fn(void* ud, voxgig_value* args) {
  int sc = (int)(intptr_t)ud;
  const char* url = "";
  if (voxgig_is_list(args) && 0 < voxgig_as_list(args)->len) {
    voxgig_value* u = voxgig_as_list(args)->items[0];
    if (voxgig_is_string(u)) url = voxgig_as_string(u);
  }
  return respond(sc, url);
}

// Offline, as every generated suite is: the test OPTION resolves a required
// server variable to test-<name>, and installs no transport. A construction
// that fails aborts, which no harness can catch, so the option is the guard.
static voxgig_value* offline(voxgig_value* opts) {
  setp(opts, "test", cmap(1, "active", v_bool(true)));
  return opts;
}

static ${Name}SDK* make_sdk_with(int sc, voxgig_value* cleanopts, Feature* extra,
    voxgig_value* auth) {
  voxgig_value* feature = v_map();
  for (size_t i = 0; FEATURES[i]; i++) {
    const char* name = FEATURES[i];
    voxgig_value* fopts = cmap(1, "active", v_bool(true));
    if (0 == strcmp(name, "log")) setp(fopts, "logger", vfn(capture_fn, (void*)"log"));
    else if (0 == strcmp(name, "debug")) setp(fopts, "onEntry", vfn(capture_fn, (void*)"debug"));
    else if (0 == strcmp(name, "audit")) setp(fopts, "sink", vfn(capture_fn, (void*)"audit"));
    else if (0 == strcmp(name, "telemetry")) setp(fopts, "exporter", vfn(capture_fn, (void*)"telemetry"));
    else if (0 == strcmp(name, "cost")) setp(fopts, "sink", vfn(capture_fn, (void*)"cost"));
    setp(feature, name, fopts);
  }

  voxgig_value* clean = cmap(1, "values", v_str(CANARY_VALUE));
  if (voxgig_is_map(cleanopts)) {
    voxgig_map* m = voxgig_as_map(cleanopts);
    for (size_t i = 0; i < m->len; i++) {
      setp(clean, m->entries[i].key, voxgig_retain(m->entries[i].value));
    }
  }

  voxgig_value* opts = cmap(6,
    "apikey", v_str(CANARY_APIKEY),
    "secret", v_str(CANARY_SECRET),
    "headers", cmap(1, "X-Custom-Token", v_str(CANARY_HEADER)),
    "clean", clean,
    "feature", feature,
    "system", cmap(1, "fetch", vfn(transport_fn, (void*)(intptr_t)sc)));
  if (auth) setp(opts, "auth", auth);
  ${Name}SDK* sdk = ${ident}_sdk_new(offline(opts));

  // C options are pure data, so the extension feature is added after
  // construction (the \`extend\` option of the ts client).
  CaptureFeature* cf = (CaptureFeature*)calloc(1, sizeof(CaptureFeature));
  cf->base.vt = &CAPTURE_VT;
  sdk_features_push(sdk, (Feature*)cf);
  if (extra) sdk_features_push(sdk, extra);

  return sdk;
}

static ${Name}SDK* make_sdk(int sc, voxgig_value* cleanopts, Feature* extra) {
  return make_sdk_with(sc, cleanopts, extra, NULL);
}

// What the operation returned, and the match its entity then holds.
typedef PNError* (*Drive)(${Name}SDK* sdk, voxgig_value* mtch, voxgig_value* ctrl, voxgig_value** out,
    voxgig_value** match);
typedef voxgig_value* (*Streamer)(${Name}SDK* sdk, voxgig_value* mtch, voxgig_value* callopts, PNError** err);

${drivers}
// Generated: every CRUD operation of every active entity, list and load
// first (they need no body), with the path parameters its points declare.
static const struct { const char* name; Drive fn; Streamer stream; const char* params[16]; } CANDIDATES[] = {
${table}
  { NULL, NULL, NULL, { NULL } },
};

typedef struct {
  Drive fn;
  Streamer stream;
  voxgig_value* mtch;
} Target;

// The first operation that completes against a plain 200: with no
// arguments, else with every path parameter its points declare filled in.
static bool usable_op(Target* target) {
  ${Name}SDK* plain = ${ident}_sdk_new(offline(cmap(2,
    "apikey", v_str(CANARY_APIKEY),
    "system", cmap(1, "fetch", vfn(transport_fn, (void*)(intptr_t)SC_OK)))));
  for (size_t i = 0; CANDIDATES[i].name; i++) {
    voxgig_value* filled = v_map();
    for (size_t p = 0; CANDIDATES[i].params[p]; p++) {
      setp(filled, CANDIDATES[i].params[p], v_str("p1"));
    }
    voxgig_value* tries[2] = { v_map(), filled };
    for (int t = 0; t < 2; t++) {
      voxgig_value* out = NULL;
      PNError* err = CANDIDATES[i].fn(plain, voxgig_clone(tries[t]), NULL, &out, NULL);
      if (!err) {
        target->fn = CANDIDATES[i].fn;
        target->stream = CANDIDATES[i].stream;
        target->mtch = tries[t];
        return true;
      }
    }
  }
  return false;
}

static PNError* drive(${Name}SDK* sdk, Target* target, voxgig_value* ctrl) {
  // A caller may keep the record it passed rather than read ctrl.explain.
  voxgig_value* held = ctrl ? getp(ctrl, "explain") : NULL;
  voxgig_value* out = NULL;
  voxgig_value* match = NULL;
  PNError* err = target->fn(sdk, voxgig_clone(target->mtch), ctrl, &out, &match);
  if (err) {
    push_error("error", err);
  } else {
    push_value("result", out ? out : v_undef());
  }
  // Raw, as a caller copying the match into another query reads it.
  push_value("match", match ? match : v_undef());
  voxgig_value* explain = ctrl ? getp(ctrl, "explain") : NULL;
  if (v_is_map(explain)) push_value("explain", explain);
  if (v_is_map(held) && held != explain) push_value("explain:held", held);
  return err;
}

// Header maps keep the caller's spelling; the assertion should not care.
static const char* header(voxgig_value* map, const char* name) {
  if (!voxgig_is_map(map)) return NULL;
  voxgig_map* m = voxgig_as_map(map);
  for (size_t i = 0; i < m->len; i++) {
    if (0 == strcasecmp(m->entries[i].key, name)) {
      voxgig_value* v = m->entries[i].value;
      return voxgig_is_string(v) ? voxgig_as_string(v) : voxgig_stringify(v, -1);
    }
  }
  return NULL;
}

static size_t leaks(const char* text, char* found, size_t cap) {
  size_t n = 0;
  found[0] = '\\0';
  for (size_t i = 0; i < NFORMS; i++) {
    if (strstr(text, FORMS[i])) {
      if (n) strncat(found, ", ", cap - strlen(found) - 1);
      strncat(found, FORMS[i], cap - strlen(found) - 1);
      n++;
    }
  }
  return n;
}

static bool ends_with(const char* s, const char* suffix) {
  size_t sl = strlen(s);
  size_t xl = strlen(suffix);
  return sl >= xl && 0 == strcmp(s + sl - xl, suffix);
}

int main(void) {
  build_forms();

  Target target;
  if (!usable_op(&target)) {
    printf("SKIP: no operation of this SDK completes against a plain 200; nothing to sweep\\n");
    return 0;
  }
  Target* op = &target;

  PNError* notfound = NULL;
  voxgig_value* explained = NULL;

  for (int sc = 0; sc < SC_COUNT; sc++) {
    for (int variant = 0; variant < 3; variant++) {
      ${Name}SDK* sdk = make_sdk(sc, NULL, NULL);
      voxgig_value* explain = v_map();
      voxgig_value* ctrl = NULL;
      if (1 == variant) ctrl = cmap(1, "explain", explain);
      if (2 == variant) ctrl = cmap(2, "throw", v_bool(false), "explain", explain);
      PNError* err = drive(sdk, op, ctrl);
      if (SC_NOTFOUND == sc && 0 == variant) notfound = err;
      if (SC_OK == sc && 1 == variant) explained = explain;
      (void)SC_NAMES;
    }
  }

  // A name given at run time replaces the declared one: the match leaves
  // out whichever name prepare_auth placed.
  drive(make_sdk_with(SC_OK, NULL, NULL, cmap(1, "name", v_str("zzcred"))), op, NULL);

  // A credential mistyped as a map. The C validator defaults rather than
  // rejects, so what the constructor produced is swept instead: a string
  // quoting the value, cleaned the way a validation message is.
  ${Name}SDK* mistyped = ${ident}_sdk_new(offline(cmap(2,
    "apikey", cmap(1, "value", v_str(CANARY_APIKEY)),
    "clean", cmap(1, "values", v_str(CANARY_VALUE)))));
  {
    char quoted[256];
    snprintf(quoted, sizeof(quoted), "apikey: expected string, got {\\"value\\":\\"%s\\"}",
             CANARY_APIKEY);
    push("mistyped:quoted", clean_str(sdk_get_root_ctx(mistyped), quoted));
  }

  // An error a feature hook raises, quoting the request, with explain on.
  Feature* thrower = (Feature*)calloc(1, sizeof(CaptureFeature));
  thrower->vt = &THROW_VT;
  PNError* hookerr = drive(make_sdk(SC_OK, NULL, thrower), op, cmap(1, "explain", v_map()));
  CHECK(hookerr != NULL, "the throwing hook should fail the operation");

  // The explain record a stream call is passed is cleaned however the stream
  // ends: from a feature's producer, or materialised by done.
  for (int s = 0; s < 2; s++) {
    const char* name = 0 == s ? "stream-ok" : "stream-plain";
    Feature* extra = NULL;
    if (0 == s) {
      extra = (Feature*)calloc(1, sizeof(CaptureFeature));
      extra->vt = &STREAMOK_VT;
    }
    voxgig_value* explain = v_map();
    PNError* serr = NULL;
    op->stream(make_sdk(SC_OK, NULL, extra), voxgig_clone(op->mtch),
               cmap(1, "ctrl", cmap(1, "explain", explain)), &serr);
    char label[64];
    snprintf(label, sizeof(label), "%s: only a failing stream raises", name);
    CHECK(NULL == serr, label);
    snprintf(label, sizeof(label), "%s: the explain record was not filled", name);
    CHECK(0 < voxgig_as_map(explain)->len, label);
    push_value(0 == s ? "stream-ok:explain" : "stream-plain:explain", explain);
  }

  // A feature's own error keeps its code, which is cleaned like the message:
  // returned, handed to a hook, and cleaned where a step's error skips
  // make_error.
  Feature* denier = (Feature*)calloc(1, sizeof(CaptureFeature));
  denier->vt = &DENY_VT;
  PNError* denied = drive(make_sdk(SC_OK, NULL, denier), op, NULL);
  CHECK(denied != NULL, "the refusing hook should fail the operation");
  char steppedcode[128];
  snprintf(steppedcode, sizeof(steppedcode), "stepped:%s", CANARY_VALUE);
  PNError* stepped = pn_error_new(steppedcode, "stepped");
  clean_error_util(sdk_get_root_ctx(mistyped), stepped);
  push("stepped", pn_error_str(stepped));

  // A client given no clean block at all masks by the schema defaults.
  ${Name}SDK* bare = ${ident}_sdk_new(offline(cmap(4,
    "apikey", v_str(CANARY_APIKEY),
    "secret", v_str(CANARY_SECRET),
    "headers", cmap(1, "X-Custom-Token", v_str(CANARY_HEADER)),
    "system", cmap(1, "fetch", vfn(transport_fn, (void*)(intptr_t)SC_NOTFOUND)))));
  PNError* barerr = drive(bare, op, NULL);
  CHECK(barerr != NULL, "the 404 scenario must throw without a clean block");

  // The raw path returns its failure rather than an error.
  PNError* directerr = NULL;
  voxgig_value* direct = sdk_direct(make_sdk(SC_TRANSPORT, NULL, NULL),
                                    cmap(1, "path", v_str("raw")), &directerr);
  bool directok = true;
  CHECK(NULL == directerr && get_bool(direct, "ok", &directok) && !directok,
        "a transport failure should fail direct()");
  push_value("direct", direct);

  size_t nleaks = 0;
  char found[4096];
  for (size_t i = 0; i < NSINKS; i++) {
    if (leaks(SINKS[i].text, found, sizeof(found))) {
      fprintf(stderr, "credential leaked through: %s [%s]\\n", SINKS[i].name, found);
      nleaks++;
    }
  }

  printf("clean: swept %zu surface(s), %zu leak(s)\\n", NSINKS, nleaks);
  CHECK(0 == nleaks, "a credential leaked (see above)");

  // The positive half: the slot the credential travelled in is masked, and
  // an unregistered token in a response header is masked by name.
  CHECK(notfound != NULL, "the 404 scenario must throw");
  if (notfound) {
    CHECK_INT_EQ(to_int(getp(notfound->result, "status")), 404, "the 404 error carries its status");
    voxgig_value* headers = getp(notfound->spec, "headers");
    if (!AUTH_SUPPRESSED) {
      if (0 == strcmp(AUTH_WHERE, "query")) {
        CHECK_STR_EQ(header(getp(notfound->spec, "query"), AUTH_NAME), MASK, "the query credential is masked");
      } else if (0 == strcmp(AUTH_WHERE, "cookie")) {
        const char* cookie = header(headers, "cookie");
        CHECK(cookie && strstr(cookie, MASK), "the cookie credential is masked");
      } else {
        const char* cred = header(headers, AUTH_NAME);
        CHECK(cred && ends_with(cred, MASK), "the header credential is masked");
      }
    }
    CHECK_STR_EQ(header(headers, "x-custom-token"), MASK, "a custom token header is masked by name");
  }

  {
    char want[64];
    snprintf(want, sizeof(want), "denied:%s", MASK);
    CHECK_STR_EQ(denied ? denied->code : NULL, want, "a feature's own error code is masked");
    snprintf(want, sizeof(want), "stepped:%s", MASK);
    CHECK_STR_EQ(stepped->code, want, "clean_error masks the code");
  }
  CHECK_STR_EQ(barerr ? header(getp(barerr->spec, "headers"), "x-custom-token") : NULL, MASK,
               "a client with no clean block masks by the schema defaults");

  CHECK(explained != NULL && voxgig_is_map(getp(explained, "result")),
        "the explain record should carry the result");
  if (explained) {
    CHECK_STR_EQ(header(getp(getp(explained, "result"), "headers"), "x-session-token"), MASK,
                 "a response token header is masked by name");
  }

  // The negative control: with clean switched off the canary MUST show, or
  // the sweep is blind.
  size_t before = NSINKS;
  ${Name}SDK* raw = make_sdk(SC_NOTFOUND, cmap(1, "active", v_bool(false)), NULL);
  PNError* rawerr = drive(raw, op, NULL);
  CHECK(rawerr != NULL, "the 404 scenario must throw with clean off");
  size_t shown = 0;
  for (size_t i = before; i < NSINKS; i++) {
    if (leaks(SINKS[i].text, found, sizeof(found))) shown++;
  }
  CHECK(0 < shown, "with clean off, nothing showed the canary: the sweep is blind");
  if (rawerr && !AUTH_SUPPRESSED) {
    char* text = voxgig_jsonify(rawerr->spec, NULL);
    char pair[256];
    snprintf(pair, sizeof(pair), "%s:%s", CANARY_APIKEY, CANARY_SECRET);
    char* pairb64 = b64(pair);
    CHECK(strstr(text, CANARY_APIKEY) || strstr(text, pairb64),
          "the raw spec should carry the credential when clean is off");
  }

  // Explaining a failure must not cost it its error.
  {
    voxgig_value* out = NULL;
    PNError* explained = op->fn(make_sdk(SC_NOTFOUND, cmap(1, "active", v_bool(false)), NULL),
                                voxgig_clone(op->mtch), cmap(1, "explain", v_map()), &out, NULL);
    CHECK_STR_EQ(explained ? explained->msg : NULL, rawerr ? rawerr->msg : NULL,
                 "with clean off, explain lost the error");
  }

  // A registered value used as a property name is masked; names that mask
  // alike are all kept.
  ${Name}SDK* named = ${ident}_sdk_new(offline(cmap(1,
    "clean", cmap(1, "values", v_str("ZZVAL-abc123,ZZVAL-xyz789")))));
  voxgig_value* renamed = clean_util(sdk_get_root_ctx(named), cmap(3,
    "ZZVAL-abc123", v_num(1), "ZZVAL-xyz789", v_num(2), "plain", v_num(3)));
  voxgig_map* rm = voxgig_as_map(renamed);
  CHECK(3 == rm->len, "every masked name is kept");
  if (3 == rm->len) {
    char alt[64];
    snprintf(alt, sizeof(alt), "%s#1", MASK);
    CHECK_STR_EQ(rm->entries[0].key, MASK, "a registered value used as a name is masked");
    CHECK_STR_EQ(rm->entries[1].key, alt, "a colliding masked name takes a counter");
    CHECK_STR_EQ(rm->entries[2].key, "plain", "an ordinary name is kept");
  }

  // The generated config's own clean block is honoured, and left unchanged.
  {
    voxgig_value* config = cmap(1, "options", cmap(1, "clean", cmap(2,
      "keys", v_str("zzsens"), "values", v_str("CONFIG-SEEDED-1"))));
    CtxSpec cs;
    memset(&cs, 0, sizeof(cs));
    cs.options = cmap(1, "clean", cmap(1, "values", v_str("CALLER-SEEDED-2")));
    cs.config = config;
    Context* cctx = make_context_util(cs, NULL);
    cctx->options = make_options_util(cctx);
    char want[128];
    snprintf(want, sizeof(want), "a %s b %s", MASK, MASK);
    CHECK_STR_EQ(clean_str(cctx, "a CONFIG-SEEDED-1 b CALLER-SEEDED-2"), want,
                 "the config's and the caller's values are both masked");
    voxgig_value* out = clean_util(cctx, cmap(2, "my_zzsens", v_str("x"), "other", v_str("y")));
    CHECK_STR_EQ(get_str(out, "my_zzsens"), MASK, "the config's key name is sensitive");
    CHECK_STR_EQ(get_str(out, "other"), "y", "an ordinary name is kept");
    voxgig_value* cfgclean = getpath2(config, "options", "clean");
    CHECK_STR_EQ(get_str(cfgclean, "keys"), "zzsens", "the config's keys are left alone");
    CHECK_STR_EQ(get_str(cfgclean, "values"), "CONFIG-SEEDED-1",
                 "the config's values are left alone");
  }

  // A feature's name is not a field name: a feature called secrets does not
  // make its settings secret, though a sensitive field inside it still is. An
  // entity block, of per-entity settings or seeded records keyed by entity
  // name and id, is not read at all, and nor are rbac's rules, keyed by entity
  // and operation names.
  {
    ${Name}SDK* featured = ${ident}_sdk_new(offline(cmap(3,
      "apikey", v_str(CANARY_APIKEY),
      "feature", cmap(3,
        "secrets", cmap(3,
          "active", v_bool(false),
          "name", v_str("ZZNAME-feat123"),
          "token", v_str("ZZTOKEN-feat456")),
        "rbac", cmap(2,
          "active", v_bool(false),
          "rules", cmap(1, "zztoken.load", v_str("PLAINRULE-k7j5h3g1"))),
        "test", cmap(2,
          "active", v_bool(false),
          "entity", cmap(1, "zztoken", cmap(1, "ZZTOKEN01",
            cmap(1, "note", v_str("PLAINRECORD-t5r3e1w9")))))),
      "entity", cmap(1, "zztoken", cmap(1, "alias",
        cmap(1, "zzkey", v_str("PLAINALIAS-m2n4b6v8")))))));
    Context* fctx = sdk_get_root_ctx(featured);
    char want[128];
    snprintf(want, sizeof(want), "ZZNAME-feat123 %s", MASK);
    CHECK_STR_EQ(clean_str(fctx, "ZZNAME-feat123 ZZTOKEN-feat456"), want,
                 "only the sensitive field of a feature is registered");
    CHECK_STR_EQ(clean_str(fctx, "record PLAINRECORD-t5r3e1w9"), "record PLAINRECORD-t5r3e1w9",
                 "a record seeded under an entity block is not registered");
    CHECK_STR_EQ(clean_str(fctx, "alias PLAINALIAS-m2n4b6v8"), "alias PLAINALIAS-m2n4b6v8",
                 "an entity's own settings are not registered");
    CHECK_STR_EQ(clean_str(fctx, "rule PLAINRULE-k7j5h3g1"), "rule PLAINRULE-k7j5h3g1",
                 "an rbac rule keyed by entity and operation is not registered");
  }

  TEST_SUMMARY("clean");
}
`
}


function cstr(s: string): string {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}


export {
  TestClean
}
