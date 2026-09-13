
import {
  nom,
} from '@voxgig/apidef'

import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, snakify, Folder, File, Content, entityCollection,
  targetFeatures, TestControl } from '@voxgig/sdkgen'


import { TestDirect } from './TestDirect_dart'
import { TestEntity } from './TestEntity_dart'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_dart'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const entity = each(entityCollection(model))
    .filter((e: any) => false !== e.active)

  // GATED SUITES. test/main.dart is a HAND-LISTED suite entry - dart has no
  // `go test ./...` or pytest discovery - so a feature whose tests ship in
  // its own trimmable folder has to be registered here or it is dead
  // weight. Both halves matter, and they fail in opposite directions:
  // register unconditionally and a project without the feature imports a
  // file that is not there (a compile error); forget to register and the
  // suite ships, never runs, and the lane stays green while nothing is
  // checked. The feature list is tag-gated, so a target with no vendored
  // sekreto never reaches this.
  const feature = targetFeatures(model, target)
  const secrets = null != feature.secrets

  Folder({ name: 'test' }, () => {

    // Write-once: a project's edited control file survives regeneration.
    TestControl({ target, dir: 'test' })

    // Suite entry: registers every static suite plus the generated
    // per-entity suites, then runs them (Makefile: dart run test/main.dart).
    File({ name: 'main.' + target.ext }, () => {

      Content(`// ${model.const.Name} SDK test suite entry. GENERATED — do not edit.

import 'dart:io';

import 'harness.dart' as harness;

import 'exists_test.dart' as exists_test;
import 'omni_smoke_test.dart' as omni_smoke_test;
import 'struct_test.dart' as struct_test;
import 'primary_test.dart' as primary_test;
import 'pipeline_test.dart' as pipeline_test;
import 'feature_test.dart' as feature_test;
import 'netsim_test.dart' as netsim_test;
import 'custom_test.dart' as custom_test;
import 'readme_examples_test.dart' as readme_examples_test;
`)

      if (secrets) {
        Content(`import 'feature/secrets/secrets_test.dart' as secrets_test;
`)
      }

      each(entity, (ent: ModelEntity) => {
        const alias = snakify(ent.name)
        Content(`import 'entity/${ent.name}/${nom(ent, 'Name')}Entity_test.dart' as ${alias}_entity_test;
`)
        if (hasDirect(ent)) {
          Content(`import 'entity/${ent.name}/${nom(ent, 'Name')}Direct_test.dart' as ${alias}_direct_test;
`)
        }
      })

      Content(`
Future<void> main() async {
  exists_test.tests();
  omni_smoke_test.tests();
  struct_test.tests();
  primary_test.tests();
  pipeline_test.tests();
  feature_test.tests();
  netsim_test.tests();
  custom_test.tests();
  readme_examples_test.tests();
`)

      if (secrets) {
        Content(`  secrets_test.tests();
`)
      }

      each(entity, (ent: ModelEntity) => {
        const alias = snakify(ent.name)
        Content(`  ${alias}_entity_test.tests();
`)
        if (hasDirect(ent)) {
          Content(`  ${alias}_direct_test.tests();
`)
        }
      })

      Content(`
  final failed = await harness.runAll();
  if (0 < failed) {
    exitCode = 1;
  }
}
`)
    })

    // Documentation dart-examples presence & completeness gate.
    ReadmeExamplesTest({ target })

    Folder({ name: 'entity' }, () => {
      each(entity, (ent: ModelEntity) => {
        TestEntity({ target, entity: ent })
        TestDirect({ target, entity: ent })
      })
    })
  })
})


// A Direct test file is generated only when the entity has load or list.
function hasDirect(entity: any): boolean {
  const opnames = Object.keys(entity.op || {})
  return opnames.includes('load') || opnames.includes('list')
}


export {
  Test
}
