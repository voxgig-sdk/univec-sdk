
import { cmp, Content } from '@voxgig/sdkgen'


const ReadmeExplanation = cmp(function ReadmeExplanation(props: any) {
  const { target, ctx$: { model } } = props

  Content(`### Data as \`voxgig_value*\`

The C SDK uses a single dynamic \`voxgig_value*\` type throughout rather than
a typed struct per entity. \`voxgig_value\` is the vendored voxgig struct
port (a JSON-shaped tagged union: string, number, bool, list, map, null,
undef). This mirrors the dynamic nature of the API and keeps the SDK
flexible — no code generation is needed when the API schema changes.

Build request maps with the \`cmap\` / \`clist\` / \`v_str\` / \`v_num\` /
\`v_bool\` helper builders, and read fields back with \`getp\` (or the typed
\`get_str\` / \`get_bool\` / \`to_int\`); use \`to_map\` to safely coerce a
value to a map.

Memory follows a retain-heavy, never-free discipline — pipeline values are
never released. This is safe (no use-after-free) and leaks are acceptable
for the short-lived SDK and test binaries.

### Error handling

Fallible functions return a \`voxgig_value*\` (or a struct pointer) and take a
trailing \`PNError** err\` out-param. On success \`*err\` is left \`NULL\`; on
failure \`*err\` points to a heap \`PNError\` carrying \`code\` and \`msg\`.
Always initialise \`PNError* err = NULL;\` and branch on it after each call.

### Project structure

\`\`\`
${target.name}/
├── core/          -- Pipeline types, config, client (client.c), api.h + sdk.h
├── entity/        -- Per-entity implementations (one .c each)
├── feature/       -- Built-in features (base, test, log, ...)
├── utility/       -- Utilities + the vendored voxgig struct port (utility/struct)
├── tests/         -- Test binaries (each a standalone main())
└── Makefile       -- Builds libsdk.a and runs every tests/*.c
\`\`\`

The public entry header is \`core/api.h\` — it includes \`core/sdk.h\` (the
umbrella runtime header) and declares each entity's constructor and SDK
accessor. Include it and link against \`libsdk.a\`.

`)

})


export {
  ReadmeExplanation
}
