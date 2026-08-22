
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, File, Content, entityCollection } from '@voxgig/sdkgen'


import { TestEntity } from './TestEntity_c'
import { TestDirect } from './TestDirect_c'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_c'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const Name = model.const.Name

  Folder({ name: 'tests' }, () => {

    // exists test — the SDK constructs in test mode.
    File({ name: 'exists_test.c' }, () => {
      Content(`// Generated existence test: the SDK constructs in test mode.

#include "ctest.h"

int main(void) {
  ${Name}SDK* testsdk = test_sdk(NULL, NULL);
  CHECK(testsdk != NULL, "test_sdk returns a client");
  CHECK_STR_EQ(testsdk->mode, "test", "test_sdk mode is test");
  TEST_SUMMARY("exists");
}
`)
    })

    const entity = each(entityCollection(model))
      .filter((e: any) => false !== e.active)

    each(entity, (entity: ModelEntity) => {
      TestEntity({ target, entity })
      TestDirect({ target, entity })
    })

    // Validate the documented C examples in the READMEs are well-formed.
    ReadmeExamplesTest({ target })
  })
})


export {
  Test
}
