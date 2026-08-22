
import { cmp, Content } from '@voxgig/sdkgen'

import { dartPackageName } from './Package_dart'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  const Name = model.const.Name
  const pkg = dartPackageName(model)

  Content(`### Maps in, typed models alongside

The Dart SDK passes plain \`Map<String, dynamic>\` values through the
operation pipeline rather than requiring typed objects at every call. This
mirrors the dynamic nature of the API and keeps calls terse — a create is
just \`create({'name': 'example'})\`.

For a typed, documented view of each entity and operation, the generated
\`${Name}Types.dart\` provides a class per entity plus per-op request/match
classes (e.g. \`${Name}.fromMap(entity.data())\` and \`model.toMap()\`), so you
can convert to and from those maps wherever you want compile-time structure.

### Package structure

\`\`\`
${target.name}/
├── lib/
│   ├── ${Name}SDK.dart          -- Main SDK library (exported entry point)
│   ├── ${Name}Types.dart        -- Typed entity + request/match models
│   ├── ${Name}EntityBase.dart   -- Base class for entities
│   ├── ${Name}Error.dart        -- SDK error type
│   ├── Config.dart              -- Configuration
│   ├── entity/                  -- Entity implementations
│   ├── feature/                 -- Built-in features (base, test, log, ...)
│   └── utility/                 -- Utility functions and vendored struct library
└── test/                        -- Test suites (dart run test/main.dart)
\`\`\`

The main library (\`${Name}SDK.dart\`) re-exports the SDK class, the typed
models, and every entity class, so a single
\`import 'package:${pkg}/${Name}SDK.dart';\`
brings in everything you need.

`)

})


export {
  ReadmeExplanation
}
