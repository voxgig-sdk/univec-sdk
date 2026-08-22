
import { cmp, Content, isAuthActive, envName, canonKey, entityIdField, pickExampleEntity, opRequestShape } from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'

import { ocamlVarName } from './utility_ocaml'


// A type-correct OCaml `value` literal for a field's canonical type.
function ocamlLit(type: any): string {
  const k = canonKey(type)
  if ('INTEGER' === k || 'NUMBER' === k) return '(Num 1.)'
  if ('BOOLEAN' === k) return '(Bool true)'
  if ('ARRAY' === k) return '(empty_list ())'
  if ('OBJECT' === k) return '(empty_map ())'
  return '(Str "example")'
}


const ReadmeHowto = cmp(function ReadmeHowto(props: any) {
  const { target, ctx$: { model } } = props

  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Pick an entity with a real op (prefer a read op) — never fabricate a
  // `load` on an op-less entity. primaryOp is null only when NO entity exposes
  // any op (a direct()-only SDK).
  const { entity: exampleEntity, primaryOp } = pickExampleEntity(entity)
  const fn = exampleEntity ? ocamlVarName(exampleEntity.name) : 'entity'
  const idF = exampleEntity ? entityIdField(exampleEntity) : null
  const field = primaryOp
    ? ('load' === primaryOp ? 'e_load' :
      'list' === primaryOp ? 'e_list' :
        'create' === primaryOp ? 'e_create' :
          'update' === primaryOp ? 'e_update' : 'e_remove')
    : ''
  const isMatchOp = 'load' === primaryOp || 'remove' === primaryOp
  let testArg = 'Noval'
  if (exampleEntity && 'list' === primaryOp) {
    testArg = '(empty_map ())'
  } else if (exampleEntity && isMatchOp) {
    testArg = idF ? `(jo [("${idF}", Str "test01")])` : '(empty_map ())'
  } else if (exampleEntity && ('create' === primaryOp || 'update' === primaryOp)) {
    const items = opRequestShape(exampleEntity, primaryOp).items
      .filter((it: any) => it.name !== idF && it.name !== 'id')
    const required = items.filter((it: any) => !it.optional)
    const chosen = required.length ? required : items.slice(0, 3)
    testArg = `(jo [${chosen.map((it: any) => `("${it.name}", ${ocamlLit(it.type)})`).join('; ')}])`
  }

  // The op-driven test-mode line, shown only when the SDK has an entity op.
  // A direct()-only SDK (no ops anywhere) shows a direct() call instead.
  const testModeExample = primaryOp
    ? ('list' === primaryOp
      ? `(* Entity ops resolve to the ENTITY (list: one per record) and raise on error. *)
  let ${fn}s = (Sdk_client.${fn} client Noval).${field} ${testArg} Noval in
  List.iter (fun e -> print_endline (stringify (e.e_data_get ()))) ${fn}s  (* the mock records *)`
      : `(* Entity ops resolve to the ENTITY and raise on error. *)
  let ${fn} = (Sdk_client.${fn} client Noval).${field} ${testArg} Noval in
  print_endline (stringify (${fn}.e_data_get ()))  (* the mock response record *)`)
    : `let result = Sdk_client.direct client (jo [("path", Str "/api/resource"); ("method", Str "GET")]) in
  print_endline (stringify result)`

  const apikeyEnvLine = isAuthActive(model)
    ? `\n${envName(model)}_APIKEY=<your-key>`
    : ''

  Content(`### Make a direct HTTP request

For endpoints not covered by entity methods:

\`\`\`ocaml
let result = Sdk_client.direct client (jo [
    ("path", Str "/api/resource/{id}");
    ("method", Str "GET");
    ("params", jo [("id", Str "example")]);
]) in
(match getp result "ok" with
 | Bool true ->
   print_endline (stringify (getp result "status"));  (* 200 *)
   print_endline (stringify (getp result "data"))      (* response body *)
 | _ ->
   (* A non-2xx response carries status + data (the error body); a transport
      failure carries err instead. Read whichever is present. *)
   print_endline (stringify (getp result "status"));
   print_endline (stringify (getp result "err")))
\`\`\`

### Prepare a request without sending it

\`\`\`ocaml
(* prepare returns the fetch definition and raises on error. *)
let fetchdef = Sdk_client.prepare client (jo [
    ("path", Str "/api/resource/{id}");
    ("method", Str "DELETE");
    ("params", jo [("id", Str "example")]);
]) in
print_endline (stringify (getp fetchdef "url"));
print_endline (stringify (getp fetchdef "method"));
print_endline (stringify (getp fetchdef "headers"))
\`\`\`

### Use test mode

Create a mock client for unit testing — no server required:

\`\`\`ocaml
let () =
  let client = Sdk_client.test () in
  ${testModeExample}
\`\`\`

### Use a custom fetch function

Replace the HTTP transport with your own function:

\`\`\`ocaml
let mock_fetch = Func (fun _ _args _ _ ->
    jo [("status", Num 200.); ("statusText", Str "OK"); ("headers", empty_map ());
        ("json", json_thunk (jo [("id", Str "mock01")]))]) in
let client = Sdk_client.make (jo [
    ("base", Str "http://localhost:8080");
    ("system", jo [("fetch", mock_fetch)]);
]) in
ignore client
\`\`\`

### Run live tests

Create a \`.env.local\` file at the project root:

\`\`\`
${envName(model)}_TEST_LIVE=TRUE${apikeyEnvLine}
\`\`\`

Then run:

\`\`\`bash
cd ${target.name} && make test
\`\`\`

`)

})


export {
  ReadmeHowto
}
