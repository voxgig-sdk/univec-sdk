// Univec SDK — umbrella runtime header (template; Univec tokens
// are substituted at generation time). Mirrors the rust core/ pipeline
// types, but flat C with explicit heap structs + function-pointer vtables.
//
// MEMORY MODEL (read this before editing any *.c):
//   The SDK data model is the vendored voxgig struct `voxgig_value*` (see
//   utility/struct/voxgig_struct.h). Pipeline code uses a RETAIN-HEAVY,
//   NEVER-FREE discipline: values are never voxgig_release()d in pipeline
//   code. This is safe (no use-after-free / double-free) and leaks are
//   acceptable for the short-lived SDK + test binaries.
//     * rust `value.clone()` (shallow Rc share)  -> voxgig_retain / share ptr
//     * rust `vs::clone(&value)` (deep clone)     -> voxgig_clone
//   Reads go through voxgig_getprop (Group A: null == absent) which returns
//   an owned (unreleased) ref. Writes go through voxgig_setprop (borrows +
//   retains its val). Both are wrapped by the helpers below.
//
// ERROR MODEL:
//   Fallible functions return a voxgig_value* (or a struct pointer) and take
//   a trailing `PNError** err` out-param. On success *err is left NULL; on
//   error *err is set to a heap PNError and the return value is unspecified
//   (usually NULL). NULL PNError* == no error everywhere.

#ifndef UNIVEC_SDK_H
#define UNIVEC_SDK_H

#include "voxgig_struct.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Forward decls.
typedef struct Context Context;
typedef struct Utility Utility;
typedef struct UnivecSDK UnivecSDK;
typedef struct Feature Feature;
typedef struct Entity Entity;
typedef struct Operation Operation;
typedef struct Spec Spec;
typedef struct Response Response;
typedef struct SdkResult SdkResult;
typedef struct Point Point;
typedef struct Fetcher Fetcher;

// ===========================================================================
// Error (mirrors core/error.rs UnivecError)
// ===========================================================================

typedef struct PNError {
  char* sdk;   // "Univec"
  char* code;  // machine code
  char* msg;   // human message
  voxgig_value* result; // cleaned snapshot (NULL until makeError)
  voxgig_value* spec;   // cleaned snapshot (NULL until makeError)
} PNError;

PNError* pn_error_new(const char* code, const char* msg);

// ===========================================================================
// Value helpers (mirrors core/helpers.rs). All return owned (unreleased)
// refs unless noted. Never release the results in pipeline code.
// ===========================================================================

// Constructors.
voxgig_value* v_map(void);
voxgig_value* v_list(void);
voxgig_value* v_str(const char* s);
voxgig_value* v_int(int64_t n);
voxgig_value* v_num(double n);
voxgig_value* v_bool(bool b);
voxgig_value* v_null(void);
voxgig_value* v_undef(void);

// Variadic literal builders. cmap(n, key0, val0, key1, val1, ...) with n
// PAIRS; clist(n, val0, val1, ...) with n items.
voxgig_value* cmap(int npairs, ...);
voxgig_value* clist(int nitems, ...);

// Property read: Noval (undef) when absent (Group A). Owned ref.
voxgig_value* getp(voxgig_value* val, const char* key);
// Path read: keys is a NULL-terminated array of const char*.
voxgig_value* getpath_c(voxgig_value* store, const char** keys);
// Convenience: up to a few string keys.
voxgig_value* getpath2(voxgig_value* store, const char* a, const char* b);
voxgig_value* getpath3(voxgig_value* store, const char* a, const char* b, const char* c);
// Property write (no-op when val is not a node). Borrows newval.
void setp(voxgig_value* val, const char* key, voxgig_value* newval);

// Typed reads. get_str returns a borrowed const char* or NULL; get_bool/get_i64
// return via out-params (return true when present & of the right type).
const char* get_str(voxgig_value* m, const char* key);
bool get_bool(voxgig_value* m, const char* key, bool* out);
bool get_i64(voxgig_value* m, const char* key, int64_t* out);

// to_map: the value if a map, else Noval. to_int: numeric or -1.
voxgig_value* to_map(voxgig_value* v);
int64_t to_int(voxgig_value* v);

// Predicates on voxgig_value (thin wrappers, NULL-safe).
bool v_is_noval(voxgig_value* v);  // undef
bool v_is_null(voxgig_value* v);
bool v_is_map(voxgig_value* v);
bool v_is_list(voxgig_value* v);
bool v_is_str(voxgig_value* v);
bool v_is_num(voxgig_value* v);
bool v_is_func(voxgig_value* v);
bool v_eq(voxgig_value* a, voxgig_value* b);  // deep equals

// String equality helper: v is a string equal to s.
bool v_str_eq(voxgig_value* v, const char* s);

// Clock / sleep / rand (mirrors helpers.rs).
int64_t now_ms(void);
void sleep_ms(int64_t ms);
int64_t rand_int(int64_t n);

// Callables. A voxgig_value FUNC (injector-shaped) called with one arg.
voxgig_value* call_vfn(voxgig_value* f, voxgig_value* arg);
voxgig_value* call_json(voxgig_value* json);
// Wrap a plain C fn(void* ud, voxgig_value* arg)->voxgig_value* as a FUNC value.
typedef voxgig_value* (*v_simple_fn)(void* ud, voxgig_value* arg);
voxgig_value* vfn(v_simple_fn fn, void* ud);
// A json thunk returning a fixed (retained) value.
voxgig_value* json_thunk(voxgig_value* data);

PNError* unsupported_op(const char* opname, const char* entityname);

// Deep clone (vs::clone) and shallow share (retain) shortcuts.
voxgig_value* v_clone(voxgig_value* v);   // deep
voxgig_value* v_share(voxgig_value* v);   // retain (shallow)

// ===========================================================================
// Control (mirrors core/control.rs)
// ===========================================================================

typedef struct Control {
  bool has_throw;
  bool throw_v;
  PNError* err;      // NULL until set
  voxgig_value* explain; // Map when supplied, else Noval
  char* actor;
  voxgig_value* paging;  // Map when supplied, else Noval
} Control;

Control* control_new(void);
bool control_has_explain(Control* c);

// ===========================================================================
// Operation (mirrors core/operation.rs)
// ===========================================================================

struct Operation {
  char* entity;
  char* name;
  char* input;
  voxgig_value* points; // List
  voxgig_value* alias;  // Map or Noval
};

Operation* operation_new(voxgig_value* opmap);

// ===========================================================================
// Point (mirrors core/point.rs)
// ===========================================================================

struct Point {
  voxgig_value* args;
  voxgig_value* rename;
  char* method;
  char* orig;
  voxgig_value* parts;
  voxgig_value* params;
  voxgig_value* select;
  bool active;
  voxgig_value* relations;
  voxgig_value* alias;
  voxgig_value* transform;
};

Point* point_new(voxgig_value* altmap);

// ===========================================================================
// Spec (mirrors core/spec.rs)
// ===========================================================================

struct Spec {
  voxgig_value* parts;
  voxgig_value* headers;
  voxgig_value* alias;
  char* base;
  char* prefix;
  char* suffix;
  voxgig_value* params;
  voxgig_value* query;
  char* step;
  char* method;
  voxgig_value* body;
  char* url;
  char* path;
};

Spec* spec_new(voxgig_value* specmap);
voxgig_value* spec_to_value(Spec* s);
// mutable string setters (free old, dup new)
void spec_set_step(Spec* s, const char* v);
void spec_set_method(Spec* s, const char* v);
void spec_set_url(Spec* s, const char* v);
void spec_set_path(Spec* s, const char* v);

// ===========================================================================
// Response (mirrors core/response.rs)
// ===========================================================================

struct Response {
  int64_t status;
  char* status_text;
  voxgig_value* headers;
  voxgig_value* json;
  voxgig_value* body;
  PNError* err;
};

Response* response_new(voxgig_value* resmap);

// ===========================================================================
// SdkResult (mirrors core/result.rs)
// ===========================================================================

// Stream producer attached by the streaming feature.
typedef voxgig_value* (*StreamFn)(void* ud); // returns a List of items

struct SdkResult {
  bool ok;
  int64_t status;
  char* status_text;
  voxgig_value* headers;
  voxgig_value* body;
  PNError* err;
  voxgig_value* resdata;
  voxgig_value* resmatch;
  voxgig_value* paging;   // Noval unless paging feature
  bool streaming;
  StreamFn stream;
  void* stream_ud;
};

SdkResult* result_new(voxgig_value* resmap);
voxgig_value* result_to_value(SdkResult* r);

// ===========================================================================
// Feature (vtable; mirrors core/types.rs Feature trait)
// ===========================================================================

typedef struct FeatureVT {
  const char* (*name)(Feature*);
  bool (*active)(Feature*);
  voxgig_value* (*add_options)(Feature*); // NULL if none
  void (*init)(Feature*, Context* ctx, voxgig_value* options);
  // Hook dispatch by name (PostConstruct, PrePoint, ...). Default no-op.
  void (*hook)(Feature*, const char* name, Context* ctx);
  // Test-support: return a fresh snapshot Map of the feature's activity
  // counters (mirrors the rust feature `track`/state fields the behavioural
  // tests inspect). Optional — a feature that tracks nothing leaves this NULL,
  // and feature_track() then returns Noval.
  voxgig_value* (*track)(Feature*);
} FeatureVT;

struct Feature {
  const FeatureVT* vt;
  // subtype-specific state follows in the concrete allocation.
};

// ===========================================================================
// Fetcher (swappable transport; features wrap it in init)
// ===========================================================================

typedef voxgig_value* (*FetchFn)(Fetcher* self, Context* ctx, const char* url,
                                 voxgig_value* fetchdef, PNError** err);
struct Fetcher {
  FetchFn fn;
  void* state; // wrapping features store {inner, options, track} here
};

// The default live transport.
voxgig_value* fetcher_util(Fetcher* self, Context* ctx, const char* url,
                           voxgig_value* fetchdef, PNError** err);

// ===========================================================================
// Utility bundle (mirrors core/utility_type.rs)
// ===========================================================================

struct Utility {
  Fetcher* fetcher;      // swappable
  voxgig_value* custom;  // Map of caller-supplied utility callables
};

Utility* utility_new(void);
Utility* utility_copy(Utility* src);
voxgig_value* utility_fetch(Utility* u, Context* ctx, const char* url,
                            voxgig_value* fetchdef, PNError** err);

// ===========================================================================
// Entity (vtable; mirrors core/types.rs Entity + UnivecEntity)
// ===========================================================================

// Every operation resolves to the ENTITY, not the raw data. `list` resolves
// to a NULL-terminated array of them, one per record; the record is reached
// through `data`. See AGENTS.md "Entity operations return ENTITIES".
//
// `voxgig_value` cannot carry an entity - it is a closed data union
// (UNDEF|NULL|BOOL|INT|DOUBLE|STRING|LIST|MAP|FUNC|SENTINEL), and adding a
// variant to a general-purpose struct library to hold SDK objects would be
// wrong - so the CONTRACT lives in these signatures instead.
typedef struct EntityVT {
  const char* (*get_name)(Entity*);
  Entity* (*make)(Entity*);
  voxgig_value* (*data)(Entity*, voxgig_value* args);   // args NULL => none
  voxgig_value* (*matchv)(Entity*, voxgig_value* args); // args NULL => none

  // `remove` resolves to the entity, marked. The instance KEEPS the data it
  // held - a caller can still read what was deleted - but it is no longer a
  // live record.
  void (*mark_deleted)(Entity*);
  bool (*deleted)(Entity*);

  // CRUD ops (UnivecEntity). On error set *err and return NULL.
  Entity* (*load)(Entity*, voxgig_value* reqmatch, voxgig_value* ctrl, PNError** err);
  // Returns a NULL-terminated Entity* array (never NULL on success).
  Entity** (*list)(Entity*, voxgig_value* reqmatch, voxgig_value* ctrl, PNError** err);
  Entity* (*create)(Entity*, voxgig_value* reqdata, voxgig_value* ctrl, PNError** err);
  Entity* (*update)(Entity*, voxgig_value* reqdata, voxgig_value* ctrl, PNError** err);
  Entity* (*remove)(Entity*, voxgig_value* reqmatch, voxgig_value* ctrl, PNError** err);
} EntityVT;

struct Entity {
  const EntityVT* vt;
  // subtype-specific state follows.
};

// ===========================================================================
// Context (mirrors core/context.rs). Plain heap struct — single threaded,
// never-free; fields are mutated in place.
// ===========================================================================

// Construction spec (rust CtxSpec). Unset fields are NULL / empty string.
typedef struct CtxSpec {
  const char* opname;       // NULL => ""
  UnivecSDK* client;
  Utility* utility;
  voxgig_value* ctrl;       // caller ctrl map (NULL => none)
  Control* ctrl_obj;        // existing control (NULL => none)
  voxgig_value* meta;
  voxgig_value* config;
  voxgig_value* entopts;
  voxgig_value* options;
  Entity* entity;
  voxgig_value* shared;
  voxgig_value* data;
  voxgig_value* reqdata;
  voxgig_value* mtch;
  voxgig_value* reqmatch;
  voxgig_value* point;
  Spec* spec;
  SdkResult* result;
  Response* response;
} CtxSpec;

// ctx.out staging kinds.
enum { OUT_NONE = 0, OUT_VAL = 1, OUT_ERR = 2 };

struct Context {
  char* id;
  // ctx.out staging (typed slots the pipeline stages read/write).
  int out_point_kind;         // OUT_NONE/OUT_VAL/OUT_ERR
  voxgig_value* out_point_val;
  PNError* out_point_err;
  Spec* out_spec;
  Response* out_request;
  Response* out_response;
  SdkResult* out_result;
  voxgig_value* out_extra;    // Map for arbitrary feature-stashed values

  Control* ctrl;
  voxgig_value* meta;
  UnivecSDK* client;
  Utility* utility;
  Operation* op;
  voxgig_value* point;
  voxgig_value* config;
  voxgig_value* entopts;
  voxgig_value* options;
  Response* response;
  SdkResult* result;
  Spec* spec;
  voxgig_value* data;
  voxgig_value* reqdata;
  voxgig_value* mtch;
  voxgig_value* reqmatch;
  Entity* entity;
  voxgig_value* shared;
};

Context* context_new(CtxSpec spec, Context* basectx);
PNError* context_make_error(Context* ctx, const char* code, const char* msg);
Utility* context_util(Context* ctx);

// ctx.out helpers.
void ctx_out_set_point_val(Context* ctx, voxgig_value* v);
void ctx_out_set_point_err(Context* ctx, PNError* e);
voxgig_value* ctx_out_extra_get(Context* ctx, const char* key);
void ctx_out_extra_set(Context* ctx, const char* key, voxgig_value* v);

// ===========================================================================
// SDK client (mirrors Main.fragment UnivecSDK) — generic fields.
// ===========================================================================

struct UnivecSDK {
  char* mode;             // "live" | "test"
  voxgig_value* options;
  Utility* utility;
  // feature list (dynamic array of Feature*).
  Feature** features;
  size_t features_len;
  size_t features_cap;
  Context* rootctx;
};

// Feature-list mutation (used by feature_add).
void sdk_features_push(UnivecSDK* sdk, Feature* f);
void sdk_features_insert(UnivecSDK* sdk, size_t i, Feature* f);
void sdk_features_replace(UnivecSDK* sdk, size_t i, Feature* f);

voxgig_value* sdk_options_map(UnivecSDK* sdk); // deep clone of options
Utility* sdk_get_utility(UnivecSDK* sdk);      // utility_copy
Context* sdk_get_root_ctx(UnivecSDK* sdk);

// Constructors / prepare / direct are in the generated client.c:
UnivecSDK* univec_sdk_new(voxgig_value* options);
UnivecSDK* test_sdk(voxgig_value* testopts, voxgig_value* sdkopts);
voxgig_value* sdk_prepare(UnivecSDK* sdk, voxgig_value* fetchargs, PNError** err);
voxgig_value* sdk_direct(UnivecSDK* sdk, voxgig_value* fetchargs, PNError** err);
voxgig_value* sdk_graphql(UnivecSDK* sdk, const char* query,
                          voxgig_value* variables, voxgig_value* ctrl,
                          PNError** err);

// Generated config (core/config.c).
voxgig_value* make_config(void);
voxgig_value* shared_config(void);
Feature* make_feature(const char* name);

// ===========================================================================
// Utility builder prototypes (utility/*.c). Fallible ones take PNError** err.
// ===========================================================================

voxgig_value* clean_util(Context* ctx, voxgig_value* val);
char* clean_str(Context* ctx, const char* val); // returns malloc'd
voxgig_value* done_util(Context* ctx, PNError** err);
voxgig_value* make_error_util(Context* ctx, PNError* err, PNError** out);
void feature_add_util(Context* ctx, Feature* f);
void feature_hook_util(Context* ctx, const char* name);
void feature_init_util(Context* ctx, Feature* f);
voxgig_value* make_fetch_def_util(Context* ctx, PNError** err);
Context* make_context_util(CtxSpec spec, Context* basectx);
voxgig_value* make_options_util(Context* ctx);
Response* make_request_util(Context* ctx, PNError** err);
Response* make_response_util(Context* ctx, PNError** err);
SdkResult* make_result_util(Context* ctx, PNError** err);
voxgig_value* make_point_util(Context* ctx, PNError** err);
Spec* make_spec_util(Context* ctx, PNError** err);
char* make_url_util(Context* ctx, PNError** err); // malloc'd
voxgig_value* param_util(Context* ctx, voxgig_value* paramdef);
Spec* prepare_auth_util(Context* ctx, PNError** err);
voxgig_value* prepare_body_util(Context* ctx);
voxgig_value* prepare_headers_util(Context* ctx);
const char* prepare_method_util(Context* ctx); // static string
voxgig_value* prepare_params_util(Context* ctx);
char* prepare_path_util(Context* ctx); // malloc'd
voxgig_value* prepare_query_util(Context* ctx);
const char* graphql_error_code(voxgig_value* gqlerr);
voxgig_value* graphql_body_util(Context* ctx);
bool graphql_errors_util(Context* ctx);
#define GRAPHQL_CONTENT_TYPE "application/json"
SdkResult* result_basic_util(Context* ctx);
SdkResult* result_body_util(Context* ctx);
SdkResult* result_headers_util(Context* ctx);
voxgig_value* transform_request_util(Context* ctx);
voxgig_value* transform_response_util(Context* ctx);

// json parse (utility/jsonparse.c) — wraps voxgig_parse_json.
voxgig_value* json_parse(const char* text); // returns Noval on error

// ===========================================================================
// Feature option readers (feature/support.c; mirrors feature/support.rs)
// ===========================================================================

bool fopt_bool(voxgig_value* options, const char* key, bool def);
int64_t fopt_int(voxgig_value* options, const char* key, int64_t def);
double fopt_num(voxgig_value* options, const char* key, double def);
const char* fopt_str(voxgig_value* options, const char* key, const char* def); // borrowed
voxgig_value* fopt_map(voxgig_value* options, const char* key); // Map or Noval
voxgig_value* fopt_list(voxgig_value* options, const char* key); // List or Noval
// Injectable clock/sleep read from options; call these directly.
int64_t fopt_now_call(voxgig_value* options);       // now()
void fopt_sleep_call(voxgig_value* options, int64_t ms);
voxgig_value* fheader_get(voxgig_value* headers, const char* name); // Noval if none
void fheader_set_default(voxgig_value* headers, const char* name, const char* value);
bool fres_status(voxgig_value* res, int64_t* out);
const char* fres_header(voxgig_value* res, const char* name); // borrowed or NULL
int64_t fparse_int(const char* s, int64_t def);

// ===========================================================================
// Feature constructors (feature/*.c).
// ===========================================================================

Feature* feature_base_new(void);
Feature* feature_log_new(void);
Feature* feature_test_new(void);
Feature* feature_retry_new(void);
Feature* feature_timeout_new(void);
Feature* feature_ratelimit_new(void);
Feature* feature_cache_new(void);
Feature* feature_idempotency_new(void);
Feature* feature_paging_new(void);
Feature* feature_streaming_new(void);
Feature* feature_proxy_new(void);
Feature* feature_telemetry_new(void);
Feature* feature_metrics_new(void);
Feature* feature_debug_new(void);
Feature* feature_audit_new(void);
Feature* feature_clienttrack_new(void);
Feature* feature_rbac_new(void);
Feature* feature_netsim_new(void);

// Test-support: snapshot a feature's activity counters (Noval if the feature
// exposes none). Backed by the optional FeatureVT.track slot.
voxgig_value* feature_track(Feature* f);

#endif // UNIVEC_SDK_H
