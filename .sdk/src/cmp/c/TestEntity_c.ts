
import {
  Model,
  ModelEntity,
} from '@voxgig/apidef'

import {
  Content,
  File,
  cmp,
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

    // The stream test drives the list op; only emit it when the entity has a
    // list op — a create/load-only entity has no list endpoint, so
    // stream("list") would error.
    const hasList = null != (entity.op && (entity.op as any)?.list)
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

    Content(`
  TEST_SUMMARY("${evar}_entity");
}
`)
  })
})


export {
  TestEntity
}
