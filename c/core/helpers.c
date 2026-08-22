// Shared Value helpers for the Univec SDK pipeline (mirrors
// core/helpers.rs). The data model is the vendored voxgig struct value.
// Retain-heavy, never-free: results are owned but never released here.

#include "sdk.h"

#include <stdarg.h>
#include <stdio.h>   // snprintf
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

// ---- constructors ---------------------------------------------------------

voxgig_value* v_map(void) { return voxgig_new_map(); }
voxgig_value* v_list(void) { return voxgig_new_list(); }
voxgig_value* v_str(const char* s) { return voxgig_new_string(s ? s : ""); }
voxgig_value* v_int(int64_t n) { return voxgig_new_int(n); }
voxgig_value* v_num(double n) { return voxgig_new_double(n); }
voxgig_value* v_bool(bool b) { return voxgig_new_bool(b); }
voxgig_value* v_null(void) { return voxgig_new_null(); }
voxgig_value* v_undef(void) { return voxgig_new_undef(); }

voxgig_value* cmap(int npairs, ...) {
  voxgig_value* m = voxgig_new_map();
  va_list ap;
  va_start(ap, npairs);
  for (int i = 0; i < npairs; i++) {
    const char* k = va_arg(ap, const char*);
    voxgig_value* v = va_arg(ap, voxgig_value*);
    if (v == NULL) v = voxgig_new_undef();
    voxgig_value* key = voxgig_new_string(k);
    voxgig_setprop(m, key, v);
    voxgig_release(key);
  }
  va_end(ap);
  return m;
}

voxgig_value* clist(int nitems, ...) {
  voxgig_value* l = voxgig_new_list();
  va_list ap;
  va_start(ap, nitems);
  for (int i = 0; i < nitems; i++) {
    voxgig_value* v = va_arg(ap, voxgig_value*);
    if (v == NULL) v = voxgig_new_undef();
    voxgig_list_push(voxgig_as_list(l), voxgig_retain(v));
  }
  va_end(ap);
  return l;
}

// ---- reads / writes -------------------------------------------------------

voxgig_value* getp(voxgig_value* val, const char* key) {
  voxgig_value* k = voxgig_new_string(key);
  voxgig_value* r = voxgig_getprop(val, k, NULL);
  voxgig_release(k);
  return r;
}

voxgig_value* getpath_c(voxgig_value* store, const char** keys) {
  voxgig_value* p = voxgig_new_list();
  for (size_t i = 0; keys[i] != NULL; i++) {
    voxgig_list_push(voxgig_as_list(p), voxgig_new_string(keys[i]));
  }
  voxgig_value* r = voxgig_getpath(store, p, NULL);
  voxgig_release(p);
  return r;
}

voxgig_value* getpath2(voxgig_value* store, const char* a, const char* b) {
  const char* keys[3] = {a, b, NULL};
  return getpath_c(store, keys);
}
voxgig_value* getpath3(voxgig_value* store, const char* a, const char* b, const char* c) {
  const char* keys[4] = {a, b, c, NULL};
  return getpath_c(store, keys);
}

void setp(voxgig_value* val, const char* key, voxgig_value* newval) {
  if (!val) return;
  voxgig_value* k = voxgig_new_string(key);
  voxgig_setprop(val, k, newval ? newval : voxgig_new_undef());
  voxgig_release(k);
}

const char* get_str(voxgig_value* m, const char* key) {
  voxgig_value* v = getp(m, key);
  if (voxgig_is_string(v)) return voxgig_as_string(v);
  return NULL;
}

bool get_bool(voxgig_value* m, const char* key, bool* out) {
  voxgig_value* v = getp(m, key);
  if (voxgig_is_bool(v)) {
    if (out) *out = voxgig_as_bool(v);
    return true;
  }
  return false;
}

bool get_i64(voxgig_value* m, const char* key, int64_t* out) {
  voxgig_value* v = getp(m, key);
  if (voxgig_is_int(v)) {
    if (out) *out = voxgig_as_int(v);
    return true;
  }
  if (voxgig_is_double(v)) {
    if (out) *out = (int64_t)voxgig_as_double(v);
    return true;
  }
  return false;
}

voxgig_value* to_map(voxgig_value* v) {
  if (voxgig_is_map(v)) return v;
  return voxgig_new_undef();
}

int64_t to_int(voxgig_value* v) {
  if (voxgig_is_int(v)) return voxgig_as_int(v);
  if (voxgig_is_double(v)) return (int64_t)voxgig_as_double(v);
  return -1;
}

// ---- predicates -----------------------------------------------------------

bool v_is_noval(voxgig_value* v) { return !v || voxgig_is_undef(v); }
bool v_is_null(voxgig_value* v) { return v && voxgig_is_null(v); }
bool v_is_map(voxgig_value* v) { return v && voxgig_is_map(v); }
bool v_is_list(voxgig_value* v) { return v && voxgig_is_list(v); }
bool v_is_str(voxgig_value* v) { return v && voxgig_is_string(v); }
bool v_is_num(voxgig_value* v) { return v && voxgig_is_number(v); }
bool v_is_func(voxgig_value* v) { return v && voxgig_is_func(v); }
bool v_eq(voxgig_value* a, voxgig_value* b) { return voxgig_equals(a, b); }

bool v_str_eq(voxgig_value* v, const char* s) {
  return voxgig_is_string(v) && strcmp(voxgig_as_string(v), s ? s : "") == 0;
}

voxgig_value* v_clone(voxgig_value* v) { return voxgig_clone(v); }
voxgig_value* v_share(voxgig_value* v) { return v ? voxgig_retain(v) : voxgig_new_undef(); }

// ---- clock / sleep / rand -------------------------------------------------

int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void sleep_ms(int64_t ms) {
  if (ms > 0) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
  }
}

static int64_t RAND_SEED = 0;
int64_t rand_int(int64_t n) {
  if (n <= 0) return 0;
  if (RAND_SEED == 0) {
    RAND_SEED = now_ms() ^ 123456789;
    RAND_SEED &= 0x7fffffff;
    if (RAND_SEED == 0) RAND_SEED = 123456789;
  }
  RAND_SEED = (RAND_SEED * 1103515245 + 12345) & 0x7fffffff;
  return RAND_SEED % n;
}

// ---- callables ------------------------------------------------------------

voxgig_value* call_vfn(voxgig_value* f, voxgig_value* arg) {
  if (!voxgig_is_func(f)) return voxgig_new_undef();
  // The vendored value calls injector-shaped fns; use the internal caller.
  // We route through a minimal injection: voxgig_new_injector stores fn+ud
  // and struct's value has no public "call" — so we call the fn pointer via
  // the boxed voxgig_func. Access through the union.
  const voxgig_func* nf = &((struct voxgig_value*)f)->as.fn;
  if (nf->kind == VOXGIG_FUNC_INJECTOR && nf->fn.inj) {
    return nf->fn.inj(NULL, arg, "", voxgig_new_undef(), nf->ud);
  }
  return voxgig_new_undef();
}

voxgig_value* call_json(voxgig_value* json) { return call_vfn(json, voxgig_new_undef()); }

// vfn / json_thunk adapters: wrap a simple fn as an injector-shaped FUNC.
typedef struct {
  v_simple_fn fn;
  void* ud;
} SimpleClosure;

static voxgig_value* simple_inj(voxgig_injection* inj, voxgig_value* val,
                                const char* ref, voxgig_value* store, void* ud) {
  (void)inj; (void)ref; (void)store;
  SimpleClosure* c = (SimpleClosure*)ud;
  return c->fn(c->ud, val);
}

voxgig_value* vfn(v_simple_fn fn, void* ud) {
  SimpleClosure* c = (SimpleClosure*)malloc(sizeof(SimpleClosure));
  c->fn = fn;
  c->ud = ud;
  return voxgig_new_injector(simple_inj, c);
}

typedef struct { voxgig_value* data; } ThunkClosure;
static voxgig_value* thunk_fn(void* ud, voxgig_value* arg) {
  (void)arg;
  ThunkClosure* c = (ThunkClosure*)ud;
  return voxgig_retain(c->data);
}
voxgig_value* json_thunk(voxgig_value* data) {
  ThunkClosure* c = (ThunkClosure*)malloc(sizeof(ThunkClosure));
  c->data = voxgig_retain(data);
  return vfn(thunk_fn, c);
}

PNError* unsupported_op(const char* opname, const char* entityname) {
  char buf[256];
  snprintf(buf, sizeof(buf), "operation '%s' not supported by entity '%s'",
           opname, entityname);
  return pn_error_new("unsupported_op", buf);
}
