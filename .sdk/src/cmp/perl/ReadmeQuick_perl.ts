
import { cmp, Content, isAuthActive, envName, canonKey, opRequestShape, entityIdField, entityDataIdField, entityOps } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'


const ReadmeQuick = cmp(function ReadmeQuick(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  const exampleEntity = Object.values(entity).find((e: any) => e.active !== false) as any

  // Find a nested entity if available: one with a parent chain
  // (relations.ancestors), an active load op, and a required non-id load
  // param to demonstrate (the parent key, e.g. page_id).
  const nestedEntity = Object.values(entity).find((e: any) =>
    e.active !== false &&
    e.relations && e.relations.ancestors && 0 < e.relations.ancestors.length &&
    entityOps(e).includes('load') &&
    opRequestShape(e, 'load').items.some((it: any) =>
      !it.optional && it.name !== entityIdField(e))
  ) as any

  const authActive = isAuthActive(model)
  const ctor = authActive
    ? `${model.const.Name}SDK->new({\n    'apikey' => $ENV{'${envName(model)}_APIKEY'},\n})`
    : `${model.const.Name}SDK->new`

  Content(`### 1. Create a client

\`\`\`perl
use lib 'lib';
use ${model.const.Name}SDK;

my $client = ${ctor};
\`\`\`

`)

  if (exampleEntity) {
    const eName = nom(exampleEntity, 'Name')
    const article = /^[aeiou]/i.test(eName) ? 'an' : 'a'
    const eVar = eName.toLowerCase()
    const opnames = entityOps(exampleEntity)
    // `idF` is the id-like MATCH field name (or null). `dataIdF` is the id on
    // the RETURNED record's data type — an entity can key its match on an id it
    // does not carry as data.
    const idF = entityIdField(exampleEntity)
    const dataIdF = entityDataIdField(exampleEntity)

    // A type-correct, executable Perl literal for a param.
    const perlLit = (type: any, placeholder: string = 'example'): string => {
      const k = canonKey(type)
      if ('INTEGER' === k || 'NUMBER' === k) return '1'
      if ('BOOLEAN' === k) return '1'
      if ('ARRAY' === k) return '[]'
      if ('OBJECT' === k) return '{}'
      return `'${placeholder}'`
    }

    if (opnames.includes('list')) {
      Content(`### 2. List ${eName.toLowerCase()} records

\`list()\` returns an \`arrayref\` of records (each a \`hashref\`) and dies on
error — iterate it directly.

\`\`\`perl
my $${eVar}s = eval { $client->${eName}->list };
if (my $err = $@) {
    print "list failed: $err\\n";
}
else {
    for my $${eVar} (@$${eVar}s) {
        print "$${eVar}->{id}\\n";
    }
}
\`\`\`

`)
    }

    if (nestedEntity) {
      const neName = nom(nestedEntity, 'Name')
      const neArticle = /^[aeiou]/i.test(neName) ? 'an' : 'a'
      const neVar = neName.toLowerCase()

      // Model-driven match: every REQUIRED load-match key. Parent keys (e.g.
      // page_id) first, the entity's own id last.
      const neIdF = entityIdField(nestedEntity)
      const neRequired = opRequestShape(nestedEntity, 'load').items
        .filter((it: any) => !it.optional)
        .sort((a: any, b: any) =>
          (a.name === neIdF ? 1 : 0) - (b.name === neIdF ? 1 : 0))
      const parentItem = neRequired.find((it: any) => it.name !== neIdF) as any
      const parentParam = parentItem && parentItem.name
      const parentName = parentParam ? parentParam.replace(/_id$/, '') : 'its parent'
      const neMatch = neRequired.map((it: any) =>
        `'${it.name}' => ${perlLit(it.type,
          it.name === neIdF ? 'example_id' : 'example_' + it.name)}`)

      Content(`### 3. Load ${neArticle} ${neName.toLowerCase()}

${neName} is nested under ${parentName}, so provide the \`${parentParam}\`.
\`load()\` returns the ENTITY — call data_get for the record — and dies on error.

\`\`\`perl
my $${neVar} = eval { $client->${neName}->load({ ${neMatch.join(', ')} }) };
if (my $err = $@) {
    print "load failed: $err\\n";
}
else {
    print "$${neVar}->{id}\\n";
}
\`\`\`

`)
    }
    else if (opnames.includes('load')) {
      const loadRequired = opRequestShape(exampleEntity, 'load').items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      const loadArg = 0 < loadRequired.length
        ? `{ ${loadRequired.map((it: any) =>
          `'${it.name}' => ${perlLit(it.type,
            it.name === idF ? 'example_id' : 'example_' + it.name)}`).join(', ')} }`
        : ''

      Content(`### 3. Load ${article} ${eName.toLowerCase()}

\`load()\` returns the ENTITY — call data_get for the record — and dies on error.

\`\`\`perl
my $${eVar} = eval { $client->${eName}->load(${loadArg}) };
if (my $err = $@) {
    print "load failed: $err\\n";
}
else {
    print "$${eVar}->{id}\\n";
}
\`\`\`

`)
    }

    // Model-driven example fields: derive the create/update body from the op
    // shape so the docs reference REAL writable fields. ids are rendered
    // separately as the match key for update/remove; a REQUIRED create id
    // stays (the call is invalid without it).
    const examplePairs = (opname: string): string[] => {
      const items = opRequestShape(exampleEntity, opname).items
        .filter((it: any) => (it.name !== idF && it.name !== 'id') ||
          ('create' === opname && !it.optional))
      const required = items.filter((it: any) => !it.optional)
      const optional = items.filter((it: any) => it.optional)
      const chosen = 'create' === opname
        ? (required.length ? required : items.slice(0, 2))
        : required.concat(optional).slice(0, Math.max(2, required.length))
      return chosen.map((it: any) => `'${it.name}' => ${perlLit(it.type, 'example_' + it.name)}`)
    }

    const idParamType = (opname: string): any => {
      const it = opRequestShape(exampleEntity, opname).items.find((x: any) => x.name === idF)
      return it && it.type
    }
    const idValueFor = (opname: string): string => (null != dataIdF && opnames.includes('create'))
      ? `$created->{${dataIdF}}`
      : perlLit(idParamType(opname), 'example_id')

    if (opnames.includes('create') || opnames.includes('update') || opnames.includes('remove')) {
      Content(`### 4. Create, update, and remove

\`\`\`perl
`)
      if (opnames.includes('create')) {
        Content(`# Create — returns the ENTITY (call data_get for the record)
my $created = $client->${eName}->create({ ${examplePairs('create').join(', ')} });

`)
      }
      if (opnames.includes('update')) {
        const updatePairs = (idF ? [`'${idF}' => ${idValueFor('update')}`] : []).concat(examplePairs('update'))
        const fromCreated = null != dataIdF && opnames.includes('create')
        Content(`# Update${fromCreated ? " — the created record's id is a plain hash key" : ''}
$client->${eName}->update({ ${updatePairs.join(', ')} });

`)
      }
      if (opnames.includes('remove')) {
        const removePairs = opRequestShape(exampleEntity, 'remove').items
          .filter((it: any) => !it.optional || it.name === idF)
          .sort((a: any, b: any) =>
            (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
          .map((it: any) => it.name === idF
            ? `'${it.name}' => ${idValueFor('remove')}`
            : `'${it.name}' => ${perlLit(it.type, 'example_' + it.name)}`)
        Content(`# Remove
$client->${eName}->remove(${removePairs.length ? `{ ${removePairs.join(', ')} }` : ''});
`)
      }
      Content(`\`\`\`

`)
    }
  }
})


export {
  ReadmeQuick
}
