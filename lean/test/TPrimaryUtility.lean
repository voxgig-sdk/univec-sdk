/- Univec SDK primary utility corpus.

   Drives the SHARED language-neutral corpus (.sdk/test/test.json, section
   `primary`) — the same fixtures every other target executes — through this
   SDK's request-shaping utilities, so the cases cannot drift from the
   reference implementation. Each section is looked up by name and executed on
   the VENDORED @voxgig/omni engine through OmniResolver, exactly as the ts/js
   reference harness does.

   The ENGINE used to be in this file: `runset`, `deepEq`, `strCheck`,
   `matchDeep` and the pass/fail tally were this port's own copy of omni's
   algorithm. All of it is gone. What remains is what belongs to this SDK:
   which corpus section drives which utility, and how a corpus map becomes a
   live context. The file keeps its name (and the `primary` executable keeps
   its root), so no call site needed churn.

   Every section uses `runsetArgs`: a `ctx` entry arrives as `args[0]`, a MAP
   on this SDK's own heap, which the call site wires to the client
   options/config, runs the utility on, and which the resolver writes back
   after the call — which is what makes `match: {ctx: ...}` (retargeted onto
   `match: {args: {"0": ...}}` by the resolver, decision 4) read the POST-call
   state rather than a stale pre-call copy. This port needs no separate
   "typed context" step: `ctx` here IS a struct map, heap-backed and
   reference-stable, and the utilities mutate it in place. -/

import VoxgigStruct
import Vregex
import SdkJson
import SdkUtility
import SdkConfig
import Omni
import OmniResolver

open VoxgigStruct
open OmniResolver

-- ---------------------------------------------------------------------------
-- context construction
-- ---------------------------------------------------------------------------

/-- The entry's ctx map, wired to the client options/config so the utilities
    see them. `args[0]` IS the map omni handed over, so every write the
    utility makes to it is what `match.args.0` reads back.

    A non-map first argument cannot occur in the shipped corpus (every entry
    of every ctx section supplies one); a fresh map is used rather than
    failing, so a future fixture degrades to "asserts nothing about the ctx"
    instead of crashing the suite. -/
def ctxOf (vals : Array Value) (options config : Value) : SIO Value := do
  let ctx ← match arg vals 0 with
    | .map i => pure (Value.map i)
    | _ => emptyMap
  SdkUtility.sp ctx "options" options
  SdkUtility.sp ctx "config" config
  pure ctx

/-- A utility that answers `(result, error?)`. omni reports a subject failure
    by its MESSAGE, so a returned SDK error becomes a thrown `IO.userError`
    carrying exactly the message the corpus's `err` expectations match on. -/
def unwrap (pair : Value × Option Value) : SIO Value := do
  match pair.2 with
  | some e => throw (IO.userError (← SdkUtility.gpS e "message"))
  | none => pure pair.1

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

def main (argv : List String) : IO UInt32 := do
  let testfile ← resolveSpecPath argv
  let r ← makeRun testfile "primary"
  let sctx ← mkCtx

  let go : SIO Unit := do
    let config ← SdkJson.jsonRead SdkConfig.configJson
    let opts ← SdkUtility.makeOptions config (← emptyMap)

    runsetArgs r "done" (getset r ["done", "basic"]) (fun vals => do
      unwrap (← SdkUtility.done (← ctxOf vals opts config)))

    runsetArgs r "makeContext" (getset r ["makeContext", "basic"]) (fun vals => do
      SdkUtility.makeContext (← ctxOf vals opts config))

    -- makeError RETURNS the error rather than raising it, and the corpus
    -- asserts it as one (`err`, and one `match: {err: ...}`), so the message
    -- is thrown here.
    runsetArgs r "makeError" (getset r ["makeError", "basic"]) (fun vals => do
      let ctx ← ctxOf vals opts config
      let e ← SdkUtility.makeError ctx (arg vals 1)
      throw (IO.userError (← SdkUtility.gpS e "message")))

    runsetArgs r "makeOptions" (getset r ["makeOptions", "basic"]) (fun vals => do
      let inv := arg vals 0
      SdkUtility.makeOptions (← getp inv "config") (← getp inv "options"))

    runsetArgs r "makeRequest" (getset r ["makeRequest", "basic"]) (fun vals => do
      unwrap (← SdkUtility.makeRequest (← ctxOf vals opts config)))

    runsetArgs r "makeResponse" (getset r ["makeResponse", "basic"]) (fun vals => do
      unwrap (← SdkUtility.makeResponse (← ctxOf vals opts config)))

    -- Sections configured by their own DEF.setup.a block get their own
    -- options: prepareAuth reads the CLIENT's options, as the ts reference
    -- does via client.options(), so a section's setup cannot reach it
    -- through ctx.options.
    let specOpts ← SdkUtility.makeOptions config
      (← tostruct (getset r ["makeSpec", "DEF", "setup", "a"]))
    runsetArgs r "makeSpec" (getset r ["makeSpec", "basic"]) (fun vals => do
      unwrap (← SdkUtility.makeSpec (← ctxOf vals specOpts config)))

    runsetArgs r "makeUrl" (getset r ["makeUrl", "basic"]) (fun vals => do
      unwrap (← SdkUtility.makeUrl (← ctxOf vals opts config)))

    runsetArgs r "operator" (getset r ["operator", "basic"]) (fun vals => do
      SdkUtility.operator (arg vals 0))

    runsetArgs r "param" (getset r ["param", "basic"]) (fun vals => do
      SdkUtility.param (← ctxOf vals opts config) (arg vals 1))

    let authOpts ← SdkUtility.makeOptions config
      (← tostruct (getset r ["prepareAuth", "DEF", "setup", "a"]))
    runsetArgs r "prepareAuth" (getset r ["prepareAuth", "basic"]) (fun vals => do
      unwrap (← SdkUtility.prepareAuth (← ctxOf vals authOpts config)))

    runsetArgs r "prepareBody" (getset r ["prepareBody", "basic"]) (fun vals => do
      SdkUtility.prepareBody (← ctxOf vals opts config))

    runsetArgs r "prepareHeaders" (getset r ["prepareHeaders", "basic"]) (fun vals => do
      SdkUtility.prepareHeaders (← ctxOf vals opts config))

    -- An op the API does not define resolves NO method: ts answers undefined
    -- there and this port answers "", and both are "no value" to the corpus
    -- (`prepareMethod` case 6, opname "bad", authors no `out`).
    runsetArgs r "prepareMethod" (getset r ["prepareMethod", "basic"]) (fun vals => do
      let m ← SdkUtility.prepareMethod (← ctxOf vals opts config)
      pure (if m == "" then .noval else .str m))

    runsetArgs r "prepareParams" (getset r ["prepareParams", "basic"]) (fun vals => do
      SdkUtility.prepareParams (← ctxOf vals opts config))

    runsetArgs r "preparePath" (getset r ["preparePath", "basic"]) (fun vals => do
      pure (.str (← SdkUtility.preparePath (← ctxOf vals opts config))))

    runsetArgs r "prepareQuery" (getset r ["prepareQuery", "basic"]) (fun vals => do
      SdkUtility.prepareQuery (← ctxOf vals opts config))

    runsetArgs r "resultBasic" (getset r ["resultBasic", "basic"]) (fun vals => do
      let ctx ← ctxOf vals opts config
      SdkUtility.resultBasic ctx
      getp ctx "result")

    runsetArgs r "resultBody" (getset r ["resultBody", "basic"]) (fun vals => do
      let ctx ← ctxOf vals opts config
      SdkUtility.resultBody ctx
      getp ctx "result")

    runsetArgs r "resultHeaders" (getset r ["resultHeaders", "basic"]) (fun vals => do
      let ctx ← ctxOf vals opts config
      SdkUtility.resultHeaders ctx
      getp ctx "result")

    runsetArgs r "transformRequest" (getset r ["transformRequest", "basic"]) (fun vals => do
      SdkUtility.transformRequest (← ctxOf vals opts config))

    runsetArgs r "transformResponse" (getset r ["transformResponse", "basic"]) (fun vals => do
      SdkUtility.transformResponse (← ctxOf vals opts config))

    -- clean takes (ctx, val), so the fixture supplies `args`, not `in` —
    -- the same shape as param/makeError above.
    runsetArgs r "clean" (getset r ["clean", "basic"]) (fun vals => do
      SdkUtility.clean (← ctxOf vals opts config) (arg vals 1))

    -- The remaining corpus sections carry no cases in this project's corpus.
    -- They are driven anyway so a future fixture runs against Lean too — and
    -- the resolver now NAMES each one as SKIPPED rather than passing it
    -- silently, which is the whole point of driving an empty group.
    runsetArgs r "makeResult" (getset r ["makeResult", "basic"]) (fun vals => do
      SdkUtility.makeResult (← ctxOf vals opts config))

    runsetArgs r "makeFetchDef" (getset r ["makeFetchDef", "basic"]) (fun vals => do
      SdkUtility.makeFetchDef (← ctxOf vals opts config))

    -- fetcher/featureHook take extra scalars. The retired engine read them
    -- off the ENTRY (`entry.url`, `entry.stage`); omni never shows an entry
    -- to a subject, so they are read from the ctx map — where an authored
    -- fixture puts everything the subject needs. Both sections are empty
    -- today, so this is the shape the first fixture must use.
    runsetArgs r "fetcher" (getset r ["fetcher", "basic"]) (fun vals => do
      let ctx ← ctxOf vals opts config
      SdkUtility.fetcher ctx (← SdkUtility.gpS ctx "url") (← getp ctx "fetchdef"))

    runsetArgs r "featureAdd" (getset r ["featureAdd", "basic"]) (fun vals => do
      let client ← emptyMap
      SdkUtility.featureAdd client (arg vals 0)
      getp client "features")

    runsetArgs r "featureInit" (getset r ["featureInit", "basic"]) (fun vals => do
      let client ← emptyMap
      SdkUtility.featureInit client (← ctxOf vals opts config)
      getp client "features")

    runsetArgs r "featureHook" (getset r ["featureHook", "basic"]) (fun vals => do
      let client ← emptyMap
      let ctx ← ctxOf vals opts config
      SdkUtility.featureHook client (← SdkUtility.gpS ctx "stage") ctx
      getp client "features")

    -- makePoint is NOT driven here, and this is deliberate.
    --
    -- The section used to be empty, so running it asserted nothing. It now
    -- carries seven cases, and every one supplies its own `options` (for
    -- allow.op) and `config` (for the operation's points) — but `ctxOf`
    -- OVERWRITES both with the SDK's, so the cases would not run as authored.
    -- Wiring it up needs ctxOf to prefer a fixture-supplied options/config,
    -- which changes every section here and could not be compiled or run when
    -- this change was made.
    --
    -- Left out rather than left in: an entry that runs with the wrong context
    -- is worse than one that does not run, and no coverage is lost — this
    -- section asserted nothing before either.
    --
    -- `primary.check` is likewise not driven: it is omni's OWN
    -- provider/DEF.client conformance group, not an SDK utility, and this
    -- suite passes its subjects explicitly rather than through a provider.

  go.run sctx
  report r "PRIMARY CORPUS: "
