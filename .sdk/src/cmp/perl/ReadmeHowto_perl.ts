
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

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


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op). primaryOp is null only
  // when NO entity exposes any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const eName = exampleEntity ? nom(exampleEntity, 'Name') : 'Entity'
  const eVar = eName.toLowerCase()
  // Model-driven id key: null when the entity has no id-like field, so a
  // match op takes no argument.
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = ''
  if (exampleEntity && isMatchOp) {
    testArg = idF ? `{ '${idF}' => 'test01' }` : ''
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = `{ ${chosen.map((it: any) => `'${it.name}' => ${perlLit(it.type)}`).join(', ')} }`
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() call instead.
  const testModeExample = primaryOp
    ? `# Entity ops return the ENTITY and dies on error;
# call data_get for the record.
my $${eVar} = $client->${eName}->${primaryOp}(${testArg});
# $${eVar} contains the mock response record`
    : `my $result = $client->direct({ 'path' => '/api/resource', 'method' => 'GET' });
print $result->{ok}, "\\n";`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`perl
my $result = $client->direct({
    'path' => '/api/resource/{id}',
    'method' => 'GET',
    'params' => { 'id' => 'example' },
});

if ($result->{ok}) {
    print $result->{status}, "\\n";  # 200
    print $result->{data}, "\\n";    # response body
}
else {
    # A non-2xx response carries status + data (the error body); a
    # transport-level failure carries err instead. Only one is present, so
    # read whichever is defined.
    print $result->{status}, ' ', ($result->{err} // ''), "\\n";
}
\`\`\`

### Prepare a request without sending it

\`\`\`perl
# prepare() returns the fetch definition and dies on error.
my $fetchdef = $client->prepare({
    'path' => '/api/resource/{id}',
    'method' => 'DELETE',
    'params' => { 'id' => 'example' },
});

print $fetchdef->{url}, "\\n";
print $fetchdef->{method}, "\\n";
print $fetchdef->{headers}, "\\n";
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`perl
my $client = ${model.const.Name}SDK->test(undef, undef);

${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own coderef:

\`\`\`perl
my $mock_fetch = sub {
    my ($url, $init) = @_;
    return ({
        'status' => 200,
        'statusText' => 'OK',
        'headers' => {},
        'json' => sub { { 'id' => 'mock01' } },
    }, undef);
};

my $client = ${model.const.Name}SDK->new({
    'base' => 'http://localhost:8080',
    'system' => { 'fetch' => $mock_fetch },
});
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd ${target.name} && prove -Ilib t/
\`\`\`

`)

})


export {
  ReadmeHowto
}
