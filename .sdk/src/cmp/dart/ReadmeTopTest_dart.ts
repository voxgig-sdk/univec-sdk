
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape, safeVarName, exampleVarName } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { dartPackageName } from './Package_dart'


// A type-correct Dart literal for a field's canonical type.
function dartLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return '<dynamic>[]'
  if ('OBJECT' === k) return '<String, dynamic>{}'
  return "'example'"
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const pkg = dartPackageName(model)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`dart
import 'package:${pkg}/${model.const.Name}SDK.dart';

Future<void> main() async {
  final client = ${model.const.Name}SDK.test();
`)

  if (exampleEntity && primaryOp) {
    const eName = nom(exampleEntity, 'Name')
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = ''
    if (isMatchOp) {
      // Every REQUIRED match key (id first).
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `{${items.map((it: any) =>
          `'${it.name}': ${it.name === idF ? "'test01'" : dartLit(it.type)}`).join(', ')}}`
        : ''
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `{${chosen.map((it: any) => `'${it.name}': ${dartLit(it.type)}`).join(', ')}}`
    }
    const eVar = exampleVarName(eName.toLowerCase(), 'dart') + ('list' === primaryOp ? 's' : '')
    Content(`  final ${eVar} = await client.${eName}().${primaryOp}(${arg});
  print(${eVar});
`)
  }

  Content(`}
\`\`\`
`)

})


export {
  ReadmeTopTest
}
