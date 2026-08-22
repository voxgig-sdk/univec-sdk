
import { cmp, Content, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
  nom,
} from '@voxgig/apidef'


// A type-correct Perl literal for a field's canonical type.
function perlLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '1'
  if ('BOOLEAN' === k) return '1'
  if ('ARRAY' === k) return '[]'
  if ('OBJECT' === k) return '{}'
  return "'example'"
}


const ReadmeTopTest = cmp(function ReadmeTopTest(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)

  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity.
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)

  Content(`\`\`\`perl
use lib '${target.name}/lib';
use ${model.const.Name}SDK;

my $client = ${model.const.Name}SDK->test(undef, undef);
`)

  if (exampleEntity && primaryOp) {
    const eName = nom(exampleEntity, 'Name')
    const idF = entityIdField(exampleEntity)
    const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
    let arg = ''
    if (isMatchOp) {
      // Every REQUIRED match key (id first) — the same shape that generates
      // the op's match resolution, so the block runs offline against a seeded
      // fixture.
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => !it.optional || it.name === idF)
        .sort((a: any, b: any) =>
          (a.name === idF ? 0 : 1) - (b.name === idF ? 0 : 1))
      arg = 0 < items.length
        ? `{ ${items.map((it: any) =>
          `'${it.name}' => ${it.name === idF ? "'test01'" : perlLit(it.type)}`).join(', ')} }`
        : ''
    } else if ('create' === primaryOp || 'update' === primaryOp) {
      const items = opRequestShape(exampleEntity, primaryOp).items
        .filter((it: any) => it.name !== idF && it.name !== 'id')
      const required = items.filter((it: any) => !it.optional)
      const chosen = required.length ? required : items.slice(0, 3)
      arg = `{ ${chosen.map((it: any) => `'${it.name}' => ${perlLit(it.type)}`).join(', ')} }`
    }
    // A list() result is an arrayref — name the variable accordingly.
    const eVar = eName.toLowerCase() + ('list' === primaryOp ? 's' : '')
    Content(`my $${eVar} = $client->${eName}->${primaryOp}(${arg});
`)
    if ('list' === primaryOp) {
      Content(`print scalar(@$${eVar}), " records\\n";
`)
    } else {
      Content(`print "$${eVar}->{id}\\n";
`)
    }
  }

  Content(`\`\`\`
`)

})


export {
  ReadmeTopTest
}
