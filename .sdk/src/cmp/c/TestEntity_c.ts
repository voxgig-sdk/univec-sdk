
import {
  Model,
  ModelEntity,
} from '@voxgig/apidef'

import {
  Content,
  File,
  cmp,
  opReachable,
  invalidRequest,
} from '@voxgig/sdkgen'


import { cIdent, cVarName } from './utility_c'


// Generated entity instance test: constructs the SDK in test mode, obtains
// the entity via its accessor, and verifies its name. (End-to-end CRUD
// pipeline coverage is provided by the generated direct test + the static
// sdk_pipeline_test, both driving the full pipeline via a mock transport.)
const TestEntity = cmp(function TestEntity(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model
  const entity: ModelEntity = props.entity

  const ident = cIdent(model)
  const evar = cVarName(entity.name)
  const Name = model.const.Name

  File({ name: entity.name + '_entity_test.c' }, () => {
    Content(`// Generated instance test for the ${entity.name} entity.

#include "ctest.h"

int main(void) {
  ${Name}SDK* sdk = test_sdk(NULL, NULL);
  CHECK(sdk != NULL, "sdk constructed");

  Entity* e = ${ident}_${evar}(sdk, NULL);
  CHECK(e != NULL, "entity instance");
  CHECK_STR_EQ(e->vt->get_name(e), "${entity.name}", "entity get_name");
`)

    // The stream test drives the list op with no match; only emit it when a
    // bare call can reach a list route (see helpers/opShape opReachable).
    const hasList = opReachable((entity.op as any)?.list, [])
    if (hasList) {
      Content(`
  // stream(): runs the list op through the full pipeline and returns a List
  // of items. Seed two entities via test mode; with the streaming feature
  // active it yields the feature's incremental items, else it falls back to
  // the materialised items — either way every item is yielded.
  {
    voxgig_value* seed = cmap(1, "entity",
      cmap(1, "${entity.name}",
        cmap(2,
          "strm01", cmap(1, "id", v_str("strm01")),
          "strm02", cmap(1, "id", v_str("strm02")))));
    voxgig_value* sdkopts = cmap(1, "feature",
      cmap(1, "streaming", cmap(1, "active", v_bool(true))));

    ${Name}SDK* strsdk = test_sdk(seed, sdkopts);
    Entity* se = ${ident}_${evar}(strsdk, NULL);
    PNError* serr = NULL;
    voxgig_value* items = ${evar}_stream(se, "list", NULL, NULL, &serr);
    CHECK(serr == NULL, "stream: no error");
    CHECK(v_is_list(items), "stream: returns a list");
    CHECK_INT_EQ((int64_t)voxgig_as_list(items)->len, 2, "stream: yields both items");

    // Fallback: streaming inactive still yields both materialised items.
    ${Name}SDK* plainsdk = test_sdk(seed, NULL);
    Entity* pe = ${ident}_${evar}(plainsdk, NULL);
    PNError* perr = NULL;
    voxgig_value* pitems = ${evar}_stream(pe, "list", NULL, NULL, &perr);
    CHECK(perr == NULL, "stream fallback: no error");
    CHECK_INT_EQ((int64_t)voxgig_as_list(pitems)->len, 2, "stream fallback: yields both items");
  }
`)
    }

    Content(failureTests(ident, evar, entity, hasList))

    Content(`
  TEST_SUMMARY("${evar}_entity");
}
`)
  })
})


// A failed operation fails a stream as it fails the operation: a transport
// failure, and a hook that rejects the call. The caller's ctrl stays its own,
// and an invalid request fails with validate's own error. A C hook cannot throw.
function failureTests(ident: string, evar: string, entity: ModelEntity, hasList: boolean): string {
  const feature = (name: string) =>
    `!v_is_noval(getp(getp(shared_config(), "feature"), "${name}"))`
  let out = ''

  if (hasList) {
    out += `
  {
    voxgig_value* offline = cmap(1, "net", cmap(1, "offline", v_bool(true)));
    PNError* ferr = NULL;
    Entity* fe = ${ident}_${evar}(test_sdk(offline, NULL), NULL);
    voxgig_value* fitems = ${evar}_stream(fe, "list", NULL, NULL, &ferr);
    CHECK(NULL == fitems && NULL != ferr && NULL != strstr(ferr->msg, "offline"),
      "stream: a failed operation fails the stream");

    PNError* qerr = NULL;
    Entity* qe = ${ident}_${evar}(test_sdk(offline, NULL), NULL);
    ${evar}_stream(qe, "list", NULL, cmap(1, "ctrl", cmap(1, "throw", v_bool(false))), &qerr);
    CHECK(NULL == qerr, "stream: under throw false a failed stream ends");

    if (${feature('rbac')}) {
      PNError* derr = NULL;
      Entity* de = ${ident}_${evar}(test_sdk(NULL, cmap(1, "feature",
        cmap(1, "rbac", cmap(2, "active", v_bool(true), "deny", v_bool(true))))), NULL);
      ${evar}_stream(de, "list", NULL, NULL, &derr);
      CHECK(NULL != derr && 0 == strcmp(derr->code, "rbac_denied"),
        "stream: a denied operation fails the stream");
    }
  }

  {
    voxgig_value* explain = voxgig_new_map();
    voxgig_value* ctrl = cmap(1, "explain", v_share(explain));
    PNError* cerr = NULL;
    Entity* ce = ${ident}_${evar}(test_sdk(NULL, NULL), NULL);
    ${evar}_stream(ce, "list", NULL, cmap(1, "ctrl", v_share(ctrl)), &cerr);
    CHECK(NULL == cerr && v_is_noval(getp(ctrl, "stream")),
      "stream: the caller's ctrl gains no key");
    CHECK(0 < voxgig_as_map(explain)->len, "stream: the caller's explain record is filled");
  }
`
  }

  const bad = invalidRequest(entity)
  if (null != bad) {
    const pairs = Object.entries(bad.args)
    const args = pairs
      .map(([k, v]) => JSON.stringify(k) + ', ' +
        ('number' === typeof v ? 'v_num(' + v + ')' :
          'boolean' === typeof v ? 'v_bool(' + v + ')' : 'v_str(' + JSON.stringify(v) + ')'))
      .join(', ')
    out += `
  if (${feature('validate')}) {
    PNError* verr = NULL;
    Entity* ve = ${ident}_${evar}(test_sdk(NULL, cmap(1, "feature",
      cmap(1, "validate", cmap(1, "active", v_bool(true))))), NULL);
    ve->vt->${bad.op}(ve, cmap(${pairs.length}, ${args}), NULL, &verr);
    CHECK(NULL != verr && 0 == strcmp(verr->code, "validate_failed"),
      "an invalid request fails with validate_failed");
  }
`
  }

  return out
}


export {
  TestEntity
}
