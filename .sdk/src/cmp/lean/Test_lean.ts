import {
  Content,
  File,
  Folder,
  cmp,
  each,
  entityCollection,
} from '@voxgig/sdkgen'

import {
  Model,
} from '@voxgig/apidef'


// True when an op has at least one endpoint point that needs no path params
// (a top-level operation the live smoke test can call without an id).
function hasParamFreePoint(op: any): boolean {
  if (null == op) return false
  const points = op.points || []
  for (const pt of points) {
    const params = ((pt.args || {}).params) || []
    if (params.length === 0) return true
  }
  return false
}


// True when an op selects a single record by path params — i.e. loading it by
// id is meaningful. A load whose every point is param-free is a singleton
// endpoint (`/current`): passing it an id matches no point at all, and the
// runtime raises `has no matching endpoint`.
function selectsByParams(op: any): boolean {
  if (null == op) return false
  const points = op.points || []
  for (const pt of points) {
    const params = ((pt.args || {}).params) || []
    if (0 < params.length) return true
  }
  return false
}


// Synthesize a create payload from the entity's required non-id fields.
function synthData(fields: any): any {
  const o: any = {}
  each(fields, (f: any) => {
    if (f.req && f.name !== 'id') {
      const t = String(f.type || '').toLowerCase()
      o[f.name] =
        (t.includes('number') || t.includes('integer') || t.includes('decimal')) ? 42
          : t.includes('bool') ? true
            : 'leantest'
    }
  })
  return o
}


// The generated `test/Runner.lean` exe runs TWO lanes:
//
//  - OFFLINE (always): a test-mode client seeded from the entity's generated
//    `<Entity>TestData.json` answers operations from an in-memory store, so
//    entity behaviour (list/load/create/load-back/remove) is verified with no
//    server — the same guarantee the `test` feature gives the other targets.
//  - LIVE (only when SDK_TEST_BASE is set): the same flow against a real
//    server, exercising the curl transport end to end.
const Test = cmp(async function Test(props: any) {
  const ctx$ = props.ctx$
  const target = props.target
  const model: Model = ctx$.model

  const entity = each(entityCollection(model))
    .filter((e: any) => false !== e.active)

  // Per-entity OFFLINE (test-mode) blocks: seeded store, no server.
  let offline = ''
  each(entity, (e: any) => {
    const ns = e.name.charAt(0).toUpperCase() + e.name.slice(1)
    const Name = e.Name || (e.name.charAt(0).toUpperCase() + e.name.slice(1))
    const ops = e.op || {}
    if (!ops.list && !ops.load) return

    // Only call the ops the entity actually declares. `Entity.create` is not
    // generated for a load-only entity, so emitting the create/remove block
    // unconditionally fails the build with "Unknown identifier X.create".
    // Value's constructors are spelled out (`Value.list`, not `.list`) — the
    // expected type is not known at the match scrutinee, and Lean reports the
    // dotted form as ambiguous against Std's own `.list`.
    let body = ''

    if (ops.list) {
      body += `        -- list returns every seeded entity
        let items ← ${ns}.list tclient (← emptyMap) (← emptyMap)
        let n ← (match items with | Value.list lid => do pure (← listItems lid).size | _ => pure 0)
        if n == ids.size then pass s!"${e.name}.list offline -> {n} seeded"
        else fail s!"${e.name}.list offline: got {n}, want {ids.size}"
`
    }

    if (ops.load && selectsByParams(ops.load)) {
      body += `        -- load the first seeded entity by id
        if ids.size > 0 then do
          let wid := ids[0]!
          let m ← newMap #[("id", Value.str wid)]
          let got ← ${ns}.load tclient m (← emptyMap)
          let gid ← SdkRuntime.gpS got "id"
          if gid == wid then pass s!"${e.name}.load offline (id={wid})"
          else fail s!"${e.name}.load offline: got {gid}, want {wid}"
`
    }
    // A singleton load (`/current`, `/slack`) is deliberately NOT asserted
    // here. The offline lane answers from a store keyed by entity id, so a
    // load carrying no id has nothing to look up — the only honest assertion
    // would need the model-driven match data the other targets build in their
    // TestEntity components. Until this lane is model-driven too, such an
    // entity contributes no offline block rather than a misleading one.

    if (ops.create && ops.load && ops.remove) {
      body += `        -- create -> load back -> remove, all in the store
        let newmap ← SdkRuntime.gp (← SdkRuntime.gp seed "new") "${e.name}"
        let nks ← keysof newmap
        if nks.size > 0 then do
          let payload ← SdkRuntime.gp newmap nks[0]!
          let created ← ${ns}.create tclient payload (← emptyMap)
          let cid ← SdkRuntime.gpS created "id"
          if cid == "" then fail "${e.name}.create offline returned no id" else do
            let m2 ← newMap #[("id", Value.str cid)]
            let back ← ${ns}.load tclient m2 (← emptyMap)
            if (← SdkRuntime.gpS back "id") == cid then
              pass s!"${e.name}.create/load offline (id={cid})"
            else fail s!"${e.name}.create/load offline mismatch"
            let _ ← ${ns}.remove tclient m2 (← emptyMap)
            let gone ← ${ns}.load tclient m2 (← emptyMap)
            match gone with
            | Value.map _ => fail s!"${e.name}.remove offline: still present"
            | _ => pass s!"${e.name}.remove offline (id={cid})"
`
    }

    // Nothing to assert (an entity whose only op needs path params we cannot
    // synthesise) — skip the block rather than emit an empty `do`.
    if ('' === body) return

    offline += `    -- ${e.name}: offline (test-mode) entity behaviour
    (do
      let seedPath := "../.sdk/test/entity/${e.name}/${Name}TestData.json"
      if !(← System.FilePath.pathExists seedPath) then
        IO.println s!"skip - ${e.name}: no seed at {seedPath}"
      else do
        let seed ← SdkJson.jsonRead (← IO.FS.readFile seedPath)
        let tclient ← Sdk.testSdk0 seed
        let existing ← SdkRuntime.gp (← SdkRuntime.gp seed "existing") "${e.name}"
        let ids ← keysof existing
${body})
`
  })

  // Per-entity LIVE test blocks.
  let blocks = ''
  each(entity, (e: any) => {
    const ns = e.name.charAt(0).toUpperCase() + e.name.slice(1)
    const listOp = (e.op || {}).list
    const createOp = (e.op || {}).create
    const removeOp = (e.op || {}).remove

    if (hasParamFreePoint(listOp)) {
      blocks += `    -- ${e.name}: list smoke
    (do
      let items ← ${ns}.list client (← emptyMap) (← emptyMap)
      match items with
      | Value.list lid => pass s!"${e.name}.list -> {(← listItems lid).size} items"
      | _ => fail "${e.name}.list did not return a list")
`
    }

    // Round-trip when create is param-free (creatable without an id); load and
    // remove then use the id returned by create.
    const loadOp = (e.op || {}).load
    if (hasParamFreePoint(createOp) && loadOp && removeOp) {
      const data = JSON.stringify(synthData(e.fields))
      blocks += `    -- ${e.name}: create / load / remove round-trip
    (do
      let d ← SdkJson.jsonRead ${JSON.stringify(data)}
      let created ← ${ns}.create client d (← emptyMap)
      let nid ← SdkRuntime.gpS created "id"
      if nid == "" then fail "${e.name}.create returned no id" else do
        let m ← newMap #[("id", .str nid)]
        let back ← ${ns}.load client m (← emptyMap)
        let bid ← SdkRuntime.gpS back "id"
        if bid == nid then pass s!"${e.name}.create/load round-trip (id={nid})"
        else fail s!"${e.name}.load mismatch: {bid} != {nid}"
        let _ ← ${ns}.remove client m (← emptyMap)
        pass s!"${e.name}.remove (id={nid})")
`
    }
  })

  // The live lane nests two levels deeper than the offline lane.
  const liveBlocks = blocks.split('\n').map((l) => l ? '  ' + l : l).join('\n')

  // A `do` block whose last statement is a `let` is a type error in Lean
  // ("the rest of the do block has monadic result type"), and an entirely
  // empty one does not parse at all. An API whose entities offer no op these
  // lanes can drive leaves both empty, so terminate them explicitly.
  const offlineBody = '' === offline ? '    pure ()\n' : offline
  const liveBody = '' === blocks ? '      pure ()\n' : liveBlocks

  Folder({ name: 'test' }, () => {
  File({ name: 'Runner.' + target.ext }, () => {
    Content(`-- ${model.const.Name} SDK test runner (generated by @voxgig/sdkgen).
--
-- OFFLINE lane (always): a test-mode client seeded from the generated entity
-- test data answers operations from an in-memory store — no server needed.
-- LIVE lane (only when SDK_TEST_BASE is set): the same flow over real HTTP.

import VoxgigStruct
import SdkJson
import SdkRuntime
import SdkClient

open VoxgigStruct

initialize npass : IO.Ref Nat ← IO.mkRef 0
initialize nfail : IO.Ref Nat ← IO.mkRef 0

def pass (msg : String) : SIO Unit := do
  npass.modify (· + 1)
  IO.println s!"ok   - {msg}"

def fail (msg : String) : SIO Unit := do
  nfail.modify (· + 1)
  IO.println s!"FAIL - {msg}"

def defaultBase : String := "http://localhost:8901"

def main : IO UInt32 := do
  let liveBase ← IO.getEnv "SDK_TEST_BASE"
  let ctx ← mkCtx
  let offline : SIO Unit := do
${offlineBody}  offline.run ctx
  match liveBase with
  | none => IO.println "skip - live lane (set SDK_TEST_BASE to enable)"
  | some base => do
    let live : SIO Unit := do
      let opts ← newMap #[("base", .str base)]
      let client ← Sdk.newSdk opts
${liveBody}    live.run ctx
  let p ← npass.get
  let f ← nfail.get
  IO.println ""
  IO.println s!"PASS {p}  FAIL {f}"
  if f > 0 then return 1 else return 0
`)
  })
  })
})


export {
  Test
}
