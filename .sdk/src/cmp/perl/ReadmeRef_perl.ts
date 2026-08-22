
import { cmp, each, Content, canonKey, File, isAuthActive, entityIdField, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


// A type-correct, executable Perl literal for a field's canonical type.
function perlLit(type: any, placeholder: string = 'example'): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return '1'
  if ('ARRAY' === k) return '[]'
  if ('OBJECT' === k) return '{}'
  return `'${placeholder}'`
}


// Perl has no static types; describe field shapes with idiomatic Perl terms.
function perlType(type: any): string {
  const k = canonKey(type)
  const m: Record<string, string> = {
    STRING: 'string', INTEGER: 'integer', NUMBER: 'number',
    BOOLEAN: 'boolean', ARRAY: 'arrayref', OBJECT: 'hashref', NULL: 'undef',
  }
  return m[k] || 'scalar'
}


const OP_SIGNATURES: Record<string, { sig: string, returns: string, desc: string }> = {
  load: {
    sig: 'load($reqmatch, $ctrl) -> hashref',
    returns: 'the entity data',
    desc: 'Load a single entity matching the given criteria. Returns the entity data and dies on error.',
  },
  list: {
    sig: 'list($reqmatch, $ctrl) -> arrayref',
    returns: 'an arrayref of entities',
    desc: 'List entities matching the given criteria. The match is optional — call `list` with no argument to list all records. Returns an arrayref and dies on error.',
  },
  create: {
    sig: 'create($reqdata, $ctrl) -> hashref',
    returns: 'the created entity data',
    desc: 'Create a new entity with the given data. Returns the created entity data and dies on error.',
  },
  update: {
    sig: 'update($reqdata, $ctrl) -> hashref',
    returns: 'the updated entity data',
    desc: 'Update an existing entity. The data must include the entity `id`. Returns the updated entity data and dies on error.',
  },
  remove: {
    sig: 'remove($reqmatch, $ctrl) -> hashref',
    returns: 'the removed entity data',
    desc: 'Remove the entity matching the given criteria. Dies on error.',
  },
}


const ReadmeRef = cmp(function ReadmeRef(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const entity = getModelPath(model, `main.${KIT}.entity`)
  const feature = getModelPath(model, `main.${KIT}.feature`)

  const publishedEntities = each(entity).filter((e: any) => e.active !== false)


  File({ name: 'REFERENCE.md' }, () => {

    Content(`# ${model.Name} ${target.title} SDK Reference

Complete API reference for the ${model.Name} ${target.title} SDK.


## ${model.Name}SDK

### Constructor

`)

    Content(`\`\`\`perl
use lib 'lib';
use ${model.const.Name}SDK;

my $client = ${model.const.Name}SDK->new($options);
\`\`\`

Create a new SDK client instance.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`$options\` | \`hashref\` | SDK configuration options. |
${isAuthActive(model) ? '| \`$options->{apikey}\` | \`string\` | API key for authentication. |\n' : ''}| \`$options->{base}\` | \`string\` | Base URL for API requests. |
| \`$options->{prefix}\` | \`string\` | URL prefix appended after base. |
| \`$options->{suffix}\` | \`string\` | URL suffix appended after path. |
| \`$options->{headers}\` | \`hashref\` | Custom headers for all requests. |
| \`$options->{feature}\` | \`hashref\` | Feature configuration. |
| \`$options->{system}\` | \`hashref\` | System overrides (e.g. custom fetch). |

`)


    Content(`
### Static Methods

`)

    Content(`#### \`${model.const.Name}SDK->test($testopts, $sdkopts)\`

Create a test client with mock features active. Both arguments may be \`undef\`.

\`\`\`perl
my $client = ${model.const.Name}SDK->test();
\`\`\`

`)


    Content(`
### Instance Methods

`)


    // Entity factory methods
    publishedEntities.map((ent: any) => {
      Content(`#### \`${ent.Name}($data)\`

Create a new \`${ent.Name}\` entity instance. Pass \`undef\` for no initial data.

`)
    })


    Content(`#### \`options_map() -> hashref\`

Return a deep copy of the current SDK options.

#### \`get_utility() -> utility\`

Return a copy of the SDK utility object.

#### \`direct($fetchargs) -> hashref\`

Make a direct HTTP request to any API endpoint. Returns a result \`hashref\` with \`ok\`, \`status\`, \`headers\`, and \`data\` (or \`err\` on failure). This escape hatch never dies — branch on \`$result->{ok}\`.

**Parameters:**

| Name | Type | Description |
| --- | --- | --- |
| \`$fetchargs->{path}\` | \`string\` | URL path with optional \`{param}\` placeholders. |
| \`$fetchargs->{method}\` | \`string\` | HTTP method (default: \`'GET'\`). |
| \`$fetchargs->{params}\` | \`hashref\` | Path parameter values. |
| \`$fetchargs->{query}\` | \`hashref\` | Query string parameters. |
| \`$fetchargs->{headers}\` | \`hashref\` | Request headers (merged with defaults). |
| \`$fetchargs->{body}\` | \`any\` | Request body (hashrefs are JSON-serialized). |

**Returns:** \`hashref\`

#### \`prepare($fetchargs) -> hashref\`

Prepare a fetch definition without sending. Returns the \`fetchdef\` and dies on error.

`)


    // Entity reference sections
    publishedEntities.map((ent: any) => {
      const opnames = Object.keys(ent.op || {})
      const fields = ent.fields || []
      // Model-driven id key: null when this entity has no id-like field.
      const idF = entityIdField(ent)
      const eVar = ent.name

      Content(`
---

## ${ent.Name} entity

`)

      if (ent.short) {
        Content(`${ent.short}

`)
      }

      Content(`\`\`\`perl
my $${eVar} = $client->${ent.Name};
\`\`\`

`)


      // Field schema
      if (fields.length > 0) {
        Content(`### Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
`)
        each(fields, (field: any) => {
          const req = field.req ? 'Yes' : 'No'
          const desc = field.short || ''
          Content(`| \`${field.name}\` | \`${perlType(field.type)}\` | ${req} | ${desc} |
`)
        })

        Content(`
`)

        // Field operations breakdown
        const hasFieldOps = fields.some((f: any) => f.op && Object.keys(f.op).length > 0)
        if (hasFieldOps) {
          const opcols = ['load', 'list', 'create', 'update', 'remove']
            .filter((op: string) => opnames.includes(op) && ent.op[op]?.active !== false)
          Content(`### Field Usage by Operation

| Field | ${opcols.join(' | ')} |
| --- | ${opcols.map(() => '---').join(' | ')} |
`)
          each(fields, (field: any) => {
            const fops = field.op || {}
            const cols = opcols.map((op: string) => {
              const fop = fops[op]
              if (null == fop) return '-'
              if (fop.active === false) return '-'
              return 'Yes'
            })
            Content(`| \`${field.name}\` | ${cols.join(' | ')} |
`)
          })

          Content(`
`)
        }
      }


      // Operation details
      if (opnames.length > 0) {
        Content(`### Operations

`)

        opnames.map((opname: string) => {
          const info = OP_SIGNATURES[opname]
          if (!info) return

          Content(`#### \`${info.sig}\`

${info.desc}

`)

          if ('load' === opname || 'remove' === opname) {
            const matchItems = opRequestShape(ent, opname).items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const arg = 0 < matchItems.length
              ? `{ ${matchItems.map((it: any) =>
                `'${it.name}' => ${perlLit(it.type,
                  it.name === idF ? ent.name + '_id' : it.name)}`).join(', ')} }`
              : ''
            Content(`\`\`\`perl
my $result = $client->${ent.Name}->${opname}(${arg});
\`\`\`

`)
          }
          else if ('list' === opname) {
            Content(`\`\`\`perl
my $results = $client->${ent.Name}->list;
for my $${eVar} (@$results) {
    print "$${eVar}->{id}\\n";
}
\`\`\`

`)
          }
          else if ('create' === opname) {
            const createItems = opRequestShape(ent, 'create').items
              .filter((it: any) => !it.optional)
            Content(`\`\`\`perl
my $result = $client->${ent.Name}->create({
`)
            createItems.map((it: any) => {
              Content(`    '${it.name}' => ${perlLit(it.type, 'example_' + it.name)},  # ${perlType(it.type)}
`)
            })
            Content(`});
\`\`\`

`)
          }
          else if ('update' === opname) {
            const updateItems = opRequestShape(ent, 'update').items
              .filter((it: any) => !it.optional || it.name === idF)
              .sort((a: any, b: any) =>
                (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
            const updateLines = updateItems.map((it: any) =>
              `    '${it.name}' => ${perlLit(it.type,
                it.name === idF ? ent.name + '_id' : it.name)},\n`).join('')
            Content(`\`\`\`perl
my $result = $client->${ent.Name}->update({
${updateLines}    # Fields to update
});
\`\`\`

`)
          }
        })
      }


      // Common methods
      Content(`### Common Methods

#### \`data_get() -> hashref\`

Get the entity data.

#### \`data_set($data)\`

Set the entity data.

#### \`match_get() -> hashref\`

Get the entity match criteria.

#### \`match_set($match)\`

Set the entity match criteria.

#### \`make() -> entity\`

Create a new \`${ent.Name}\` entity instance with the same options.

#### \`get_name() -> string\`

Return the entity name.

`)
    })


    // Features section
    const activeFeatures = each(feature).filter((f: any) => f.active)
    if (activeFeatures.length > 0) {
      Content(`
---

## Features

| Feature | Version | Description |
| --- | --- | --- |
`)

      activeFeatures.map((f: any) => {
        Content(`| \`${f.name}\` | ${f.version || '0.0.1'} | ${f.title || ''} |
`)
      })

      Content(`

Features are activated via the \`feature\` option:

`)

      Content(`\`\`\`perl
my $client = ${model.const.Name}SDK->new({
    'feature' => {
`)
      activeFeatures.map((f: any) => {
        Content(`        '${f.name}' => { 'active' => 1 },
`)
      })
      Content(`    },
});
\`\`\`

`)
    }

  })
})




export {
  ReadmeRef
}
