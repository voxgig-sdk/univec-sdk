
import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, Folder, File, Content, entityCollection,
  TestControl } from '@voxgig/sdkgen'


import { TestEntity } from './TestEntity_rust'
import { TestDirect } from './TestDirect_rust'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_rust'
import { crateIdent } from './utility_rust'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const rustcrate = crateIdent(model)

  Folder({ name: 'tests' }, () => {

    // Write-once: a project's edited control file survives regeneration.
    TestControl({ target, dir: 'tests' })

    // exists test — the SDK constructs in test mode.
    File({ name: 'exists_test.' + target.ext }, () => {
      Content(`// Generated existence test: the SDK constructs in test mode.

use ${rustcrate}::{test_sdk, Value};

#[test]
fn exists_test_mode() {
    let testsdk = test_sdk(Value::Noval, Value::Noval);
    assert_eq!(*testsdk.mode.borrow(), "test");
}
`)
    })

    const entity = each(entityCollection(model))
      .filter((e: any) => false !== e.active)

    each(entity, (entity: ModelEntity) => {
      TestEntity({ target, entity, rustcrate })
      TestDirect({ target, entity, rustcrate })
    })

    // Validate the documented rust examples in the READMEs are well-formed.
    ReadmeExamplesTest({ target })
  })
})


export {
  Test
}
