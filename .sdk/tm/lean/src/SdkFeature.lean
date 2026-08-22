/- Univec SDK feature catalog.

   A feature observes and modifies the operation pipeline in two ways:

   - by WRAPPING THE TRANSPORT: `init` replaces the client's fetcher with one
     that calls the previous fetcher (retry, timeout, ratelimit, cache, proxy,
     netsim, test all do this), so features compose as a middleware chain in
     add order;
   - by HANDLING A HOOK: a pipeline stage (PrePoint, PreSpec, PreRequest,
     PreResponse, PreResult, PreDone, PreUnexpected) dispatched to every active
     feature.

   Lean cannot put closures inside the struct `Value` model, so features and
   fetchers live in module-level registries and the client `Value` carries their
   indices. Timing uses the monotonic clock; where the donors use randomness we
   use a deterministic counter, which keeps generated suites reproducible. -/

import VoxgigStruct
import SdkJson
import SdkUtility

open VoxgigStruct

namespace SdkFeature

/-- Transport: ctx -> url -> fetchdef -> (response, error). -/
abbrev Fetcher := Value → String → Value → SIO (Value × Option Value)

structure Feature where
  name : String
  version : String := "0.0.1"
  /-- init ctx options -/
  init : Value → Value → SIO Unit := fun _ _ => pure ()
  /-- hook stage ctx -/
  hook : String → Value → SIO Unit := fun _ _ => pure ()

initialize featureReg : IO.Ref (Array Feature) ← IO.mkRef #[]
initialize fetcherReg : IO.Ref (Array Fetcher) ← IO.mkRef #[]
initialize seqRef : IO.Ref Nat ← IO.mkRef 0

def nextSeq : SIO Nat := do seqRef.modifyGet fun n => (n + 1, n + 1)

def nowMs : SIO Float := do pure (← IO.monoMsNow).toFloat

def sleepMs (ms : Float) : SIO Unit := do
  if ms > 0.0 then IO.sleep (ms.toUInt32) else pure ()

/-- Deterministic id (no RNG: reproducible suites). -/
def genId : SIO String := do pure ("k" ++ toString (← nextSeq))

-- ---------------------------------------------------------------------------
-- option readers
-- ---------------------------------------------------------------------------

def optActive (opts : Value) : SIO Bool := do
  match (← SdkUtility.gp opts "active") with
  | .bool b => pure b
  | _ => pure false

def optNum (opts : Value) (k : String) (d : Float) : SIO Float := do
  match (← SdkUtility.gp opts k) with
  | .num n => pure n
  | _ => pure d

def optInt (opts : Value) (k : String) (d : Int) : SIO Int := do
  match (← SdkUtility.gp opts k) with
  | .num n => pure (fToInt n)
  | _ => pure d

def optStr (opts : Value) (k d : String) : SIO String := do
  let s ← SdkUtility.gpS opts k
  pure (if s == "" then d else s)

def optStrList (opts : Value) (k : String) (d : Array String) : SIO (Array String) := do
  match (← SdkUtility.gp opts k) with
  | .list i => do
    let its ← listItems i
    pure (its.map SdkUtility.vs)
  | _ => pure d

/-- The feature's own options map (the client passes `{active, ...}`). -/
def toOptsMap (opts : Value) : SIO Value := do
  match opts with
  | .map i => pure (.map i)
  | _ => emptyMap

def upper (s : String) : String := s.toUpper
def lower (s : String) : String := s.toLower

/-- Case-insensitive header lookup. -/
def headerCI (headers : Value) (name : String) : SIO Value := do
  match headers with
  | .map i => do
    let want := lower name
    for k in (← keysof (.map i)) do
      if lower k == want then return (← SdkUtility.gp (.map i) k)
    pure .noval
  | _ => pure .noval

-- ---------------------------------------------------------------------------
-- client wiring: fetcher chain + tracking buckets
-- ---------------------------------------------------------------------------

def registerFetcher (f : Fetcher) : SIO Nat := do
  fetcherReg.modifyGet fun a => (a.size, a.push f)

def getFetcher (client : Value) : SIO Fetcher := do
  match (← SdkUtility.gp client "fetcher") with
  | .num n => do
    let reg ← fetcherReg.get
    pure (reg[fToInt n |>.toNat]!)
  | _ => pure (fun _ _ _ => do pure (.noval, none))

def setFetcher (client : Value) (f : Fetcher) : SIO Unit := do
  let id ← registerFetcher f
  SdkUtility.sp client "fetcher" (.num id.toFloat)

/-- The client of a ctx. -/
def clientOf (ctx : Value) : SIO Value := do SdkUtility.gp ctx "client"

/-- A named metrics bucket on the client's `track` map. -/
def trackBucket (client : Value) (name : String) (mk : SIO Value) : SIO Value := do
  let track ← SdkUtility.gpMap client "track"
  match (← SdkUtility.gp track name) with
  | .map i => pure (.map i)
  | _ => do
    let b ← mk
    SdkUtility.sp track name b
    pure b

def bumpNum (bucket : Value) (k : String) (n : Float) : SIO Unit := do
  let cur ← SdkUtility.gp bucket k
  let v := (match cur with | .num x => x | _ => 0.0) + n
  SdkUtility.sp bucket k (.num v)

def trackCtx (ctx : Value) (name : String) (mk : SIO Value) : SIO Value := do
  trackBucket (← clientOf ctx) name mk

-- ---------------------------------------------------------------------------
-- feature registry / dispatch
-- ---------------------------------------------------------------------------

def registerFeature (f : Feature) : SIO Nat := do
  featureReg.modifyGet fun a => (a.size, a.push f)

def clientFeatures (client : Value) : SIO (Array (Nat × Feature)) := do
  let reg ← featureReg.get
  let mut out : Array (Nat × Feature) := #[]
  match (← SdkUtility.gp client "features") with
  | .list i =>
    for fv in (← listItems i) do
      match fv with
      | .num n => do
        let idx := fToInt n |>.toNat
        if h : idx < reg.size then out := out.push (idx, reg[idx])
      | _ => pure ()
  | _ => pure ()
  pure out

/-- Is the named feature active on this client? -/
def isActive (client : Value) (name : String) : SIO Bool := do
  let fo ← SdkUtility.gp (← SdkUtility.gp client "featureopts") name
  optActive fo

/-- Dispatch a pipeline stage to every active feature. -/
def dispatch (client : Value) (stage : String) (ctx : Value) : SIO Unit := do
  for (_, f) in (← clientFeatures client) do
    if (← isActive client f.name) then
      f.hook stage ctx

end SdkFeature
