
import { cmp, Content, isAuthActive, envName, canonKey, canonScalarKey, entityIdField, opRequestShape, safeVarName, exampleVarName, matchArg, idLiteral } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'

import { dartPackageName } from './Package_dart'


// A type-correct, executable Dart literal for a param: numeric/boolean/
// array/object params render a typed literal; strings render the quoted
// placeholder (single-quoted, matching the generated Dart style).
function dartLit(type: any, placeholder: string = 'example'): string {
  const k = canonScalarKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return 'true'
  if ('ARRAY' === k) return '<dynamic>[]'
  if ('OBJECT' === k) return '<String, dynamic>{}'
  return `'${placeholder}'`
}


// A `list()` on a NESTED entity needs its parent path params. The
// quickstart used to emit `client.Moon().list()` for an entity at
// `/planet/{planet_id}/moon`, which 404s against a live server from a
// half-built URL — indistinguishable from "no such record". The model
// already marks those params `reqd: true`; matchArg renders exactly them.
function listMatchArg(ent: any): string {
  const idF = entityIdField(ent)
  return matchArg('ts', ent, 'list', idF, idLiteral(ent, 'list', idF))
}


const ReadmeTopQuick = cmp(function ReadmeTopQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const pkg = dartPackageName(model)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  const authActive = isAuthActive(model)
  const importIO = authActive ? `import 'dart:io';\n` : ''
  const ctor = authActive
    ? `${model.const.Name}SDK({\n    'apikey': Platform.environment['${envName(model)}_APIKEY'],\n  })`
    : `${model.const.Name}SDK()`

  Content(`\`\`\`dart
${importIO}import 'package:${pkg}/${model.const.Name}SDK.dart';

Future<void> main() async {
  final client = ${ctor};

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const eVar = exampleVarName(eName.toLowerCase(), 'dart')
    const opnames = Object.keys(exampleEntity.op || {})
    // Model-driven id key: null when the entity has no id-like field, in which
    // case the load example takes no match argument.
    const idF = entityIdField(exampleEntity)

    if (opnames.includes('list')) {
      Content(`  // List all ${eName.toLowerCase()}s (returns a list of entities, throws on error)
  final ${eVar}s = await client.${eName}().list(${listMatchArg(exampleEntity)});
  for (final item in ${eVar}s) {
    print(item.data());
  }
`)
    }

    if (opnames.includes('load')) {
      // Every REQUIRED load-match key (id first, then parent path params like
      // page_id) — the same shape the runtime resolves path params from, so
      // the example always works.
      const loadItems = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `{${loadItems.map((it: any) =>
          `'${it.name}': ${dartLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(', ')}}`
        : ''
      Content(`
  // Load a specific ${eName.toLowerCase()} (returns the record, throws on error)
  final ${eVar} = await client.${eName}().load(${loadArg});
  print(${eVar});
`)
    }
  }

  Content(`}
\`\`\`
`)

})


export {
  ReadmeTopQuick
}
