
import { cmp, each, Content, canonKey, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


// A type-correct, executable Perl literal for a field's canonical type. The
// create example is EXECUTED by the doc test, so a placeholder must be a real
// value. Strings render the quoted placeholder.
function perlLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return '1'
  if ('ARRAY' === k) return '[]'
  if ('OBJECT' === k) return '{}'
  return `'${placeholder}'`
}


// Perl has no static types; describe a field's shape with idiomatic Perl
// terms (scalar / arrayref / hashref) derived from the canonical sentinel.
function perlType(type: any): string {
  const k = canonKey(type)
  const m: Record<string, string> = {
    STRING: 'string', INTEGER: 'integer', NUMBER: 'number',
    BOOLEAN: 'boolean', ARRAY: 'arrayref', OBJECT: 'hashref', NULL: 'undef',
  }
  return m[k] || 'scalar'
}


// Operation method spelling for Perl: lowercase methods called on the entity
// instance, taking a hashref match/data argument.
const OP_DESC: Record<string, { method: string, desc: string }> = {
  load:   { method: 'load($match)',  desc: 'Load a single entity by match criteria.' },
  list:   { method: 'list()',        desc: 'List entities, optionally matching the given criteria.' },
  create: { method: 'create($data)', desc: 'Create a new entity with the given data.' },
  update: { method: 'update($data)', desc: 'Update an existing entity.' },
  remove: { method: 'remove($match)', desc: 'Remove the matching entity.' },
}


const ReadmeEntity = cmp(function ReadmeEntity(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const publishedEntities = each(entity)
    .filter((entity: any) => entity.active !== false)

  if (0 === publishedEntities.length) {
    return
  }

  Content(`

## Entities

`)

  publishedEntities.map((entity: any) => {
    const opnames = Object.keys(entity.op || {})
    const fields = entity.fields || []
    // Model-driven id key: null when this entity has no id-like field.
    const idF = entityIdField(entity)
    const eVar = entity.name

    Content(`
### ${entity.Name}

`)

    if (entity.short) {
      Content(`${entity.short}

`)
    }

    Content(`Create an instance: \`my $${eVar} = $client->${entity.Name};\`

`)

    if (opnames.length > 0) {
      Content(`#### Operations

| Method | Description |
| --- | --- |
`)
      opnames.map((opname: string) => {
        const info = OP_DESC[opname]
        if (info) {
          Content(`| \`${info.method}\` | ${info.desc} |
`)
        }
      })

      Content(`
`)
    }

    if (fields.length > 0) {
      Content(`#### Fields

| Field | Type | Description |
| --- | --- | --- |
`)

      each(fields, (field: any) => {
        const desc = field.short || ''
        Content(`| \`${field.name}\` | \`${perlType(field.type)}\` | ${desc} |
`)
      })

      Content(`
`)
    }

    if (opnames.includes('load')) {
      // The id key plus every REQUIRED match key (parent path params like
      // page_id) — the same shape the runtime resolves path params from, so
      // the example always works.
      const loadItems = opRequestShape(entity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadItems.length
        ? `{ ${loadItems.map((it: any) =>
          `'${it.name}' => ${perlLit(it.type,
            it.name === idF ? entity.name + '_id' : it.name)}`).join(', ')} }`
        : ''
      Content(`#### Example: Load

\`\`\`perl
my $${eVar} = $client->${entity.Name}->load(${loadArg});
\`\`\`

`)
    }

    if (opnames.includes('list')) {
      Content(`#### Example: List

\`\`\`perl
my $${eVar}s = $client->${entity.Name}->list;
\`\`\`

`)
    }

    if (opnames.includes('create')) {
      // Members come from the SAME shape the runtime validates
      // (opRequestShape): every required member must appear — including a
      // required id and parent keys like page_id — with a real, executable
      // literal.
      const createItems = opRequestShape(entity, 'create').items
        .filter((it: any) => !it.optional)
      Content(`#### Example: Create

\`\`\`perl
my $${eVar} = $client->${entity.Name}->create({
`)
      createItems.map((it: any) => {
        Content(`    '${it.name}' => ${perlLit(it.type, 'example_' + it.name)},  # ${perlType(it.type)}
`)
      })
      Content(`});
\`\`\`

`)
    }
  })
})


export {
  ReadmeEntity
}
