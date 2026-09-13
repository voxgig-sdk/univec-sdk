/* Smoke tests for the VENDORED omni runner itself (tests/vendor/omni),
 * and for the voxgig<->omni bridge in tests/omni_resolver.h.
 *
 * A runner that cannot FAIL a bad entry would turn every corpus suite
 * vacuously green, so the failure paths are pinned here, not just the
 * happy one. (The C peer of tm/ts/test/omni.test.ts,
 * tm/go/test/omnismoke_test.go and tm/java/test/OmniSmokeTest.java.)
 *
 * The subjects go through omnivx_subject, so the bridge is on every path:
 * if the omni->voxgig or voxgig->omni conversion breaks, `passes a correct
 * subject` goes red here before the corpus suites have to explain it.
 */

#include "ctest.h"         /* CHECK/CHECK_TRUE + api.h */
#include "omni_resolver.h" /* vendored omni + the voxgig<->omni bridge */
#include "voxgig_struct.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static omni_pool* POOL = NULL;

/* A minimal in-memory spec: no fixture file, no OMNI block (lenient v0,
 * like the shared corpus). Built with omni's own constructors, because
 * omni_make_runner takes either a path or an already-parsed spec. */
static omni_json* smoke_spec(void) {
  omni_json* spec = omni_map(POOL);
  omni_json* primary = omni_map(POOL);
  omni_json* smoke = omni_map(POOL);
  omni_json* group;
  omni_json* set;
  omni_json* entry;

  /* basic: two entries the subject satisfies. */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 1));
  omni_map_set(entry, "out", omni_num(POOL, 2));
  omni_list_push(set, entry);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 41));
  omni_map_set(entry, "out", omni_num(POOL, 42));
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(smoke, "basic", group);

  /* bad: the same subject must NOT satisfy this one. */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 1));
  omni_map_set(entry, "out", omni_num(POOL, 999));
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(smoke, "bad", group);

  /* err: the subject is expected to fail on 0. */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 0));
  omni_map_set(entry, "err", omni_str(POOL, "zero refused"));
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(smoke, "err", group);

  /* nested: a map+list result, so the bridge is exercised on containers
   * and on the integer/decimal split, not only on scalars. */
  group = omni_map(POOL);
  set = omni_list(POOL);
  entry = omni_map(POOL);
  omni_map_set(entry, "in", omni_num(POOL, 2));
  {
    omni_json* out = omni_map(POOL);
    omni_json* list = omni_list(POOL);
    omni_list_push(list, omni_num(POOL, 2));
    omni_list_push(list, omni_num(POOL, 2.5));
    omni_map_set(out, "n", omni_num(POOL, 3));
    omni_map_set(out, "seen", list);
    omni_map_set(out, "flag", omni_bool(POOL, 1));
    omni_map_set(entry, "out", out);
  }
  omni_list_push(set, entry);
  omni_map_set(group, "set", set);
  omni_map_set(smoke, "nested", group);

  omni_map_set(primary, "smoke", smoke);
  omni_map_set(spec, "primary", primary);

  return spec;
}

/* The subject under test, in the struct-corpus shape the resolver adapts:
 * increment, and refuse zero. */
static voxgig_value* smoke_inc(voxgig_value* in, char** err, void* ud) {
  (void)ud;
  if (!voxgig_is_number(in)) {
    *err = strdup("smoke: not a number");
    return voxgig_new_undef();
  }
  if (0 == voxgig_as_double(in)) {
    *err = strdup("smoke: zero refused");
    return voxgig_new_undef();
  }
  return voxgig_new_int((int64_t)voxgig_as_double(in) + 1);
}

/* Echoes its argument, so an entry that EXPECTS an error must fail. */
static voxgig_value* smoke_echo(voxgig_value* in, char** err, void* ud) {
  (void)err;
  (void)ud;
  return voxgig_retain(in);
}

/* Builds the nested result the `nested` group pins. */
static voxgig_value* smoke_nested(voxgig_value* in, char** err, void* ud) {
  (void)err;
  (void)ud;
  voxgig_value* out = voxgig_new_map();
  voxgig_value* seen = voxgig_new_list();
  double num = voxgig_is_number(in) ? voxgig_as_double(in) : 0;
  voxgig_list_push(voxgig_as_list(seen), voxgig_new_int((int64_t)num));
  voxgig_list_push(voxgig_as_list(seen), voxgig_new_double(num + 0.5));
  voxgig_map_set(voxgig_as_map(out), "n", voxgig_new_int((int64_t)num + 1));
  voxgig_map_set(voxgig_as_map(out), "seen", seen);
  voxgig_map_set(voxgig_as_map(out), "flag", voxgig_new_bool(true));
  return out;
}

static omni_runpack* smoke_pack(void) {
  char* err = NULL;
  omni_runner* runner = omni_make_runner(POOL, NULL, smoke_spec(), NULL, &err);
  if (NULL == runner) {
    fprintf(stderr, "omni smoke: cannot make runner: %s\n", NULL == err ? "?" : err);
    return NULL;
  }
  return omni_runner_run(runner, "smoke", NULL, &err);
}

int main(void) {
  omni_runpack* pack;
  char* err;
  int failed;

  POOL = omni_pool_new();

  pack = smoke_pack();
  CHECK(NULL != pack, "smoke spec section resolved");
  if (NULL == pack) {
    TEST_SUMMARY("omni_smoke");
  }
  CHECK(omni_ismap(omni_spec(pack)), "smoke spec is a map");

  /* 1. A correct subject passes — and with it the whole bridge. */
  err = NULL;
  failed = omni_runset(pack, omni_set(pack, "basic"), omnivx_subject(POOL, smoke_inc, NULL), &err);
  CHECK(0 == failed, "runset passes a correct subject");
  if (failed) {
    fprintf(stderr, "  %s\n", NULL == err ? "(no message)" : err);
  }

  /* 2. A container result round-trips through the bridge unchanged. */
  err = NULL;
  failed =
      omni_runset(pack, omni_set(pack, "nested"), omnivx_subject(POOL, smoke_nested, NULL), &err);
  CHECK(0 == failed, "runset passes a nested map/list result through the bridge");
  if (failed) {
    fprintf(stderr, "  %s\n", NULL == err ? "(no message)" : err);
  }

  /* 3. A WRONG result must be reported. A runner that stays green here
   *    would make every corpus suite vacuously green. */
  err = NULL;
  failed = omni_runset(pack, omni_set(pack, "bad"), omnivx_subject(POOL, smoke_inc, NULL), &err);
  CHECK(0 != failed, "runset FAILS a wrong result");
  CHECK(NULL != err && NULL != strstr(err, "result mismatch"),
        "the failure names a result mismatch");

  /* 4. An expected error is matched... */
  err = NULL;
  failed = omni_runset(pack, omni_set(pack, "err"), omnivx_subject(POOL, smoke_inc, NULL), &err);
  CHECK(0 == failed, "an expected error is matched");

  /* ...and a subject that does NOT fail must fail that same entry. */
  err = NULL;
  failed = omni_runset(pack, omni_set(pack, "err"), omnivx_subject(POOL, smoke_echo, NULL), &err);
  CHECK(0 != failed, "a missing expected error is reported");
  CHECK(NULL != err && NULL != strstr(err, "expected error did not occur"),
        "the failure names the missing error");

  /* 5. A missing subject is refused rather than skipped. */
  err = NULL;
  failed = omni_runset(pack, omni_set(pack, "basic"), NULL, &err);
  CHECK(0 != failed, "a missing subject is refused");

  /* 6. A spec section with no `set` is refused rather than passing
   *    vacuously — the guard the corpus drivers rely on. */
  err = NULL;
  failed = omni_runset(pack, omni_map(POOL), omnivx_subject(POOL, smoke_inc, NULL), &err);
  CHECK(0 != failed, "a spec with no set is refused");

  /* 7. The bridge keeps "no value at all" distinct from null: an
   *    OMNI_ABSENT argument must reach the subject as UNDEF, not as null. */
  {
    voxgig_value* got = omnivx_tovx(omni_absent(POOL));
    CHECK(voxgig_is_undef(got), "OMNI_ABSENT crosses as voxgig undef");
    voxgig_release(got);
    got = omnivx_tovx(omni_null(POOL));
    CHECK(voxgig_is_null(got), "OMNI_NULL crosses as voxgig null");
    voxgig_release(got);
  }
  {
    voxgig_value* undef = voxgig_new_undef();
    voxgig_value* nul = voxgig_new_null();
    CHECK(OMNI_ABSENT == omnivx_tomni(POOL, undef)->type, "voxgig undef crosses as OMNI_ABSENT");
    CHECK(OMNI_NULL == omnivx_tomni(POOL, nul)->type, "voxgig null crosses as OMNI_NULL");
    voxgig_release(undef);
    voxgig_release(nul);
  }

  /* 8. An integral double crosses as an INTEGER, so minor.typify and
   *    minor.typename read the same type the JSON parser gave them. */
  {
    voxgig_value* whole = omnivx_tovx(omni_num(POOL, 5));
    voxgig_value* frac = omnivx_tovx(omni_num(POOL, 5.5));
    CHECK(voxgig_is_int(whole), "an integral number crosses as voxgig int");
    CHECK(voxgig_is_double(frac), "a fractional number crosses as voxgig double");
    voxgig_release(whole);
    voxgig_release(frac);
  }

  omni_pool_free(POOL);

  TEST_SUMMARY("omni_smoke");
}
