
import {
  nom,
} from '@voxgig/apidef'

import type {
  ModelEntity
} from '@voxgig/apidef'

import { cmp, each, snakify, Folder, File, Content, entityCollection } from '@voxgig/sdkgen'


import { TestDirect } from './TestDirect_dart'
import { TestEntity } from './TestEntity_dart'
import { ReadmeExamplesTest } from './ReadmeExamplesTest_dart'


const Test = cmp(function Test(props: any) {
  const { model } = props.ctx$
  const { target } = props

  const entity = each(entityCollection(model))
    .filter((e: any) => false !== e.active)

  Folder({ name: 'test' }, () => {

    // Suite entry: registers every static suite plus the generated
    // per-entity suites, then runs them (Makefile: dart run test/main.dart).
    File({ name: 'main.' + target.ext }, () => {

      Content(`// ${model.const.Name} SDK test suite entry. GENERATED — do not edit.

import 'dart:io';

import 'harness.dart' as harness;

import 'exists_test.dart' as exists_test;
import 'struct_test.dart' as struct_test;
import 'primary_test.dart' as primary_test;
import 'pipeline_test.dart' as pipeline_test;
import 'feature_test.dart' as feature_test;
import 'netsim_test.dart' as netsim_test;
import 'custom_test.dart' as custom_test;
import 'readme_examples_test.dart' as readme_examples_test;
`)

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
  struct_test.tests();
  primary_test.tests();
  pipeline_test.tests();
  feature_test.tests();
  netsim_test.tests();
  custom_test.tests();
  readme_examples_test.tests();
`)

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
