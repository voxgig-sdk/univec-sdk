/- Univec SDK secrets feature test (`lake exe secrets`).

   Behavioural tests for the secrets feature over the vendored @voxgig/sekreto
   port. The contract under test: the `apikey` OPTION keeps its exact old
   meaning and always wins, because SecretsFeature places it FIRST in the
   provider chain (a `memory` store named `options`) - explicit-beats-lookup
   falls out of sekreto's first-hit rule rather than from special-case logic.
   With the feature inactive nothing changes at all. With it active and the
   option unset, the chain supplies the credential instead.

   THE SHAPE EVERY FAIL-CLOSED CASE TAKES, and why. Each drives a LIVE client
   whose base transport is a counting stub (SdkRuntime.mkClientWith - lean's
   spelling of the `utility: { fetcher }` seam, since a struct Value cannot
   carry a closure), so "sent" is a fact about the wire and not about a mock.
   The refusal is matched on sekreto's OWN message, so an unrelated failure
   (a missing route, a bad match) cannot stand in for it. And each case has a
   CONTROL leg: the same construction with a WORKING provider must reach the
   same transport exactly once, carrying the credential - so a zero means
   REFUSED and not UNWIRED. Delete the init gate in SecretsFeature.transport
   and the construction-failure and malformed-entry cases go RED.

   This file lives in test/feature/secrets/ on purpose: `feature add` trims it,
   with the feature source and the vendored library, for a project whose
   model does not select `secrets`. -/

import VoxgigStruct
import SdkJson
import SdkUtility
import SdkFeature
import SdkFeatures
import SdkClient
import Sekreto
import SecretsFeature

open VoxgigStruct

initialize npass : IO.Ref Nat ← IO.mkRef 0
initialize nfail : IO.Ref Nat ← IO.mkRef 0

def pass (msg : String) : SIO Unit := do
  npass.modify (· + 1)
  IO.println s!"ok   - {msg}"

def fail (msg : String) : SIO Unit := do
  nfail.modify (· + 1)
  IO.println s!"FAIL - {msg}"

def check (cond : Bool) (msg : String) : SIO Unit := do
  if cond then pass msg else fail msg

def gp := SdkUtility.gp
def gpS := SdkUtility.gpS
def sp := SdkUtility.sp

-- ---------------------------------------------------------------------------
-- the wire
-- ---------------------------------------------------------------------------

/-- A transport that records every call it is handed: how many, and the
    authorization header each carried (`none` when absent). Answers the
    status in `status`, and `next` after the first call when set - the two
    statuses an expiry-then-success needs. -/
structure Wire where
  sent : IO.Ref Nat
  auth : IO.Ref (Array (Option String))
  status : IO.Ref Float
  next : IO.Ref (Option Float)

def mkWire (status : Float := 200.0) (next : Option Float := none) : SIO Wire := do
  pure { sent := ← IO.mkRef 0, auth := ← IO.mkRef #[],
         status := ← IO.mkRef status, next := ← IO.mkRef next }

def wireFetcher (w : Wire) : SdkFeature.Fetcher := fun _ _ f => do
  w.sent.modify (· + 1)
  let a ← match (← gp f "headers") with
    | .map _ =>
      match (← gp (← gp f "headers") "authorization") with
      | .str s => pure (some s)
      | _ => pure none
    | _ => pure none
  w.auth.modify (·.push a)
  let st ← w.status.get
  match ← w.next.get with
  | some n => w.status.set n
  | none => pure ()
  let resp ← newMap #[("status", .num st), ("statusText", .str "OK"),
                      ("body", ← newMap #[("ok", .bool true)]), ("headers", ← emptyMap)]
  pure (resp, none)

/-- The authorization header the LAST request carried. -/
def lastAuth (w : Wire) : SIO (Option String) := do
  let all ← w.auth.get
  pure (if all.isEmpty then none else all[all.size - 1]!)

/-- What went out, for a failure message that names the leak. -/
def onwire (w : Wire) : SIO String := do
  let all ← w.auth.get
  pure (String.intercalate ", " (all.toList.map (fun a => "auth=" ++ (a.getD "<none>"))))

/-- Is `h` the credential `token`, under whatever prefix this API declares?
    The template cannot know the prefix (`Bearer <token>` for an http/bearer
    scheme, the bare token for an apiKey scheme), so the check is on the
    CREDENTIAL. -/
def credentialIs (h : Option String) (token : String) : Bool :=
  match h with
  | some s => s == token || s.endsWith (" " ++ token)
  | none => false

def hasText (hay needle : String) : Bool :=
  (hay.splitOn needle).length > 1

-- ---------------------------------------------------------------------------
-- clients
-- ---------------------------------------------------------------------------

/-- A LIVE client over `w`, with the given options. -/
def liveClient (w : Wire) (opts : Value) : SIO Value :=
  SdkRuntime.mkClientWith opts SdkConfig.configJson (wireFetcher w)

/-- Options: the given top-level entries, plus `feature.secrets` from
    `secrets` (an active feature block, or `.noval` for none). -/
def optsWith (top : Array (String × Value)) (secrets : Value := .noval) : SIO Value := do
  let o ← newMap top
  match secrets with
  | .map _ =>
    let fmap ← newMap #[("secrets", secrets)]
    sp o "feature" fmap
  | _ => pure ()
  pure o

/-- An active secrets block over `providers`, plus extra keys. -/
def secretsOpts (providers : Array Value) (extra : Array (String × Value) := #[])
    : SIO Value := do
  let o ← newMap #[("active", .bool true), ("providers", ← newList providers)]
  for (k, v) in extra do sp o k v
  pure o

/-- A `memory` provider spec holding `values`. -/
def memoryOf (values : Array (String × Value)) (name : String := "vault") : SIO Value := do
  newMap #[("kind", .str "memory"), ("name", .str name), ("values", ← newMap values)]

/-- The first entity with a `list` op whose points carry no path parameter:
    a subject the pipeline can drive with an empty match. -/
def findListEntity : SIO (Option String) := do
  let config ← SdkJson.jsonRead SdkConfig.configJson
  let ents ← gp config "entity"
  for name in (← keysof ents) do
    let e ← gp ents name
    match (← gp (← gp e "op") "list") with
    | .map _ =>
      let mut plain := true
      match (← gp (← gp (← gp e "op") "list") "points") with
      | .list i =>
        for pt in (← listItems i) do
          match (← gp (← gp pt "args") "params") with
          | .list ps => if 0 < (← listItems ps).size then plain := false
          | _ => pure ()
      | _ => pure ()
      if plain then return some name
    | _ => pure ()
  return none

/-- List with maps of its own: the runtime records a failure on the caller's
    options map, so a reused map filters every later list by `err`. -/
def listAll (c : Value) (ent : String) : SIO Value := do
  SdkRuntime.opList c ent (← emptyMap) (← emptyMap)

/-- Run a list op; the error MESSAGE when it refused, `none` when it went. -/
def attempt (client : Value) (ent : String) : SIO (Option String) := do
  try
    let _ ← listAll client ent
    pure none
  catch e => pure (some (toString e))

/-- The feature's observable bucket. -/
def bucket (client : Value) : SIO Value := do
  gp (← gp client "track") "secrets"

def purchases (client : Value) : SIO Float := do
  match (← gp (← bucket client) "purchases") with
  | .num n => pure n
  | _ => pure 0.0

-- A scratch directory for the `file` provider cases, under .lake so a
-- `make clean` removes it.
def SCRATCH : String := ".lake/tsecrets"

def writeSecret (key value : String) : IO Unit := do
  IO.FS.createDirAll SCRATCH
  IO.FS.writeFile (SCRATCH ++ "/" ++ key) value

def dropSecret (key : String) : IO Unit := do
  let p : System.FilePath := SCRATCH ++ "/" ++ key
  if ← p.pathExists then
    if ← p.isDir then IO.FS.removeDirAll p else IO.FS.removeFile p

-- ---------------------------------------------------------------------------
-- the cases
-- ---------------------------------------------------------------------------

def run (ent : String) : SIO Unit := do

  -- ---- inactive: nothing changes ----------------------------------------
  (do
    let w ← mkWire
    let c ← liveClient w (← optsWith #[("apikey", .str "PLAINKEY01")])
    let _ ← listAll c ent
    check ((← w.sent.get) == 1 && credentialIs (← lastAuth w) "PLAINKEY01")
      "inactive: apikey option behaves exactly as before")

  (do
    let w ← mkWire
    let c ← liveClient w (← optsWith #[])
    let _ ← listAll c ent
    check ((← w.sent.get) == 1 && (← lastAuth w).isNone)
      "inactive: no apikey means no authorization header")

  (do
    let w ← mkWire
    let off ← newMap #[("active", .bool false)]
    let c ← liveClient w (← optsWith #[("apikey", .str "PLAINKEY01")] off)
    let _ ← listAll c ent
    let feats ← match (← gp c "features") with
      | .list i => do pure (← listItems i).size
      | _ => pure 0
    check (feats == 0 && credentialIs (← lastAuth w) "PLAINKEY01")
      "inactive: a declared-off feature is not installed and touches nothing")

  -- ---- active: the chain and the explicit option ------------------------
  (do
    let w ← mkWire
    let s ← secretsOpts #[← memoryOf #[("APIKEY", .str "from-chain")]]
    let c ← liveClient w (← optsWith #[("apikey", .str "explicit")] s)
    let _ ← listAll c ent
    check (credentialIs (← lastAuth w) "explicit")
      "active: apikey option still wins over the chain")

  (do
    let w ← mkWire
    let s ← secretsOpts #[← memoryOf #[("APIKEY", .str "from-chain")]]
    let c ← liveClient w (← optsWith #[] s)
    let _ ← listAll c ent
    check (credentialIs (← lastAuth w) "from-chain")
      "active: an OMITTED apikey defers to the chain")

  (do
    let w ← mkWire
    let s ← secretsOpts #[← memoryOf #[("APIKEY", .str "from-chain")]]
    let c ← liveClient w (← optsWith #[("apikey", .str "")] s)
    let _ ← listAll c ent
    check (credentialIs (← lastAuth w) "from-chain")
      "active: an explicitly EMPTY apikey also defers to the chain")

  (do
    let w ← mkWire
    let s ← secretsOpts #[← memoryOf #[("APIKEY", .str "from-chain")]]
    let c ← liveClient w (← optsWith #[("auth", .null)] s)
    let _ ← listAll c ent
    check ((← w.sent.get) == 1 && (← lastAuth w).isNone)
      "active: auth null suppresses the credential, chain or no chain")

  (do
    let w ← mkWire
    let s ← secretsOpts #[← memoryOf #[("APIKEY", .str "from-chain")]]
    let c ← liveClient w (← optsWith #[("auth", .null), ("apikey", .str "explicit")] s)
    let _ ← listAll c ent
    check ((← w.sent.get) == 1 && (← lastAuth w).isNone)
      "active: auth null suppresses an EXPLICIT apikey too")

  (do
    let w ← mkWire
    let s ← secretsOpts #[← memoryOf #[]]
    let c ← liveClient w (← optsWith #[] s)
    let err ← attempt c ent
    check (err.isNone && (← w.sent.get) == 1 && (← lastAuth w).isNone)
      "active: a miss everywhere leaves the header off, and the op proceeds")

  (do
    let w ← mkWire
    let s ← secretsOpts #[← memoryOf #[("CUSTOM_KEY", .str "named01")]] #[("name", .str "custom.key")]
    let c ← liveClient w (← optsWith #[] s)
    let _ ← listAll c ent
    check (credentialIs (← lastAuth w) "named01") "active: secret name is configurable")

  -- ---- active: a provider ERROR refuses, a construction failure refuses,
  --      a malformed entry refuses - each with its CONTROL leg ------------
  --
  -- The error-at-lookup provider: `dotenv` pointed at a DIRECTORY. readmaybe
  -- reads it, the read fails with something other than ENOENT, the parent
  -- IS a directory, so this is an ERROR (a store that could not answer),
  -- never a miss - and sekreto names it: "sekreto: dotenv provider cannot
  -- read .: ...".
  let broken ← newMap #[("kind", .str "dotenv"), ("name", .str "broken"), ("file", .str ".")]
  let working ← memoryOf #[("APIKEY", .str "RAWKEY01")] "working"

  (do
    -- CONTROL FIRST, so the zero below is known to be observable at all.
    let cw ← mkWire
    let cc ← liveClient cw (← optsWith #[] (← secretsOpts #[working]))
    let cerr ← attempt cc ent
    check (cerr.isNone && (← cw.sent.get) == 1 && credentialIs (← lastAuth cw) "RAWKEY01")
      "control: a working provider reaches the transport exactly once, carrying the credential"

    -- THE RULE.
    let w ← mkWire
    let c ← liveClient w (← optsWith #[] (← secretsOpts #[broken]))
    let err ← attempt c ent
    check ((← w.sent.get) == 0)
      ("active: a provider ERROR fails the op rather than sending (went out: " ++ (← onwire w) ++ ")")
    check (match err with
      | some m => hasText m "sekreto: dotenv provider cannot read"
      | none => false)
      ("active: the refusal carries sekreto's own message, got: " ++ (err.getD "<no error>")))

  (do
    -- A kind sekreto has never heard of: the constructor refuses, and the
    -- gate must refuse every request with the constructor's message.
    let cw ← mkWire
    let cc ← liveClient cw (← optsWith #[] (← secretsOpts #[working]))
    let _ ← attempt cc ent
    check ((← cw.sent.get) == 1) "control: the construction-failure case can observe a request"

    let w ← mkWire
    let unknown ← newMap #[("kind", .str "nosuchkind")]
    let c ← liveClient w (← optsWith #[] (← secretsOpts #[unknown]))
    -- The feature must still be INSTALLED: a construction failure that
    -- silently uninstalled it would be the same fail-open by another route.
    let installed ← SdkFeature.isActive c "secrets"
    let err ← attempt c ent
    check installed "active: the feature stays installed on a construction failure"
    check ((← w.sent.get) == 0)
      ("active: an unbuildable chain REFUSES rather than sending (went out: " ++ (← onwire w) ++ ")")
    check (match err with
      | some m => hasText m "sekreto: unknown provider kind: nosuchkind"
      | none => false)
      ("active: the construction refusal is sekreto's own, got: " ++ (err.getD "<no error>")))

  (do
    -- A kind NAME where a spec belongs - the natural slip for a reader of
    -- the ts docs. Refused with the constructor's wording, never DROPPED:
    -- a dropped entry shortens the chain and the shortened chain sends.
    let cw ← mkWire
    let cc ← liveClient cw (← optsWith #[] (← secretsOpts #[working]))
    let _ ← attempt cc ent
    check ((← cw.sent.get) == 1) "control: the malformed-entry case can observe a request"

    let w ← mkWire
    let c ← liveClient w (← optsWith #[] (← secretsOpts #[.str "hashicorp", working]))
    let err ← attempt c ent
    check ((← w.sent.get) == 0)
      ("active: a malformed providers entry REFUSES, it is never dropped (went out: " ++ (← onwire w) ++ ")")
    check (match err with
      | some m => hasText m "sekreto: not a provider or a provider spec"
      | none => false)
      ("active: the malformed-entry refusal carries sekreto's wording, got: " ++ (err.getD "<no error>")))

  -- ---- active: recovery, and the cache ---------------------------------
  let fileSpec ← newMap #[("kind", .str "file"), ("name", .str "disk"), ("dir", .str SCRATCH)]

  (do
    -- A `file` provider whose entry is a DIRECTORY reads as an ERROR (not
    -- ENOENT, parent is a directory); replaced by a file it is a HIT. The
    -- failure must not poison the client: the next op asks again.
    dropSecret "APIKEY"
    IO.FS.createDirAll (SCRATCH ++ "/APIKEY")
    let w ← mkWire
    let c ← liveClient w (← optsWith #[] (← secretsOpts #[fileSpec]))
    let first ← attempt c ent
    dropSecret "APIKEY"
    writeSecret "APIKEY" "RECOVERED01"
    let second ← attempt c ent
    check (first.isSome && second.isNone && (← w.sent.get) == 1 &&
        credentialIs (← lastAuth w) "RECOVERED01")
      "active: a provider recovers after a transient failure"
    dropSecret "APIKEY")

  (do
    dropSecret "APIKEY"
    writeSecret "APIKEY" "one"
    let w ← mkWire
    let c ← liveClient w (← optsWith #[] (← secretsOpts #[fileSpec] #[("cache", .bool false)]))
    let _ ← attempt c ent
    let a1 ← lastAuth w
    writeSecret "APIKEY" "two"
    let _ ← attempt c ent
    let a2 ← lastAuth w
    dropSecret "APIKEY"
    let e3 ← attempt c ent
    let a3 ← lastAuth w
    check (credentialIs a1 "one" && credentialIs a2 "two")
      "active: cache false asks the chain on every resolve"
    check (e3.isNone && (← w.sent.get) == 3 && a3.isNone)
      "active: cache false, a miss after a hit RETRACTS the credential (nothing stale goes out)")

  (do
    dropSecret "APIKEY"
    writeSecret "APIKEY" "one"
    let w ← mkWire
    let c ← liveClient w (← optsWith #[] (← secretsOpts #[fileSpec]))
    let _ ← attempt c ent
    writeSecret "APIKEY" "two"
    let _ ← attempt c ent
    check (credentialIs (← lastAuth w) "one") "active: cache true keeps the first answer"
    dropSecret "APIKEY")

  -- ---- active: the plugin vocabulary -----------------------------------
  (do
    match SecretsFeature.featurePlugins with
    | [] => IO.println "skip - a selected plugin kind is in the SDK vocabulary (no plugin group selected)"
    | first :: _ =>
      -- With the definition passed, the kind is KNOWN: construction goes
      -- through (it contacts nothing). Without it, the same spec is refused
      -- with the message that names the fix. Both halves, so the test cannot
      -- pass on a chain that was never built.
      let spec : Sekreto.ProviderSpec := {
        kind := first.name, addr := "https://vault.invalid:8200", token := "t",
        project := "p", vault := "v", region := "eu-west-1", keyid := "k", secret := "s",
        command := "nosuchcommand", clientid := "c", clientsecret := "cs", tenant := "t" }
      let known ← try (do
          let _ ← Sekreto.sekreto { providers := [spec], plugins := SecretsFeature.featurePlugins }
          pure (Except.ok ()))
        catch e => pure (Except.error (Sekreto.why e))
      let unknown ← try (do
          let _ ← Sekreto.sekreto { providers := [spec], plugins := [] }
          pure (Except.ok ()))
        catch e => pure (Except.error (Sekreto.why e))
      check (match known, unknown with
        | .ok (), .error m => hasText m "is a sekreto plugin, not built in"
        | _, _ => false)
        ("active: a selected plugin kind (" ++ first.name ++ ") is in the SDK vocabulary"))

  -- ---- the exchange ----------------------------------------------------
  --
  -- A LIVE client over the counting wire, with the token endpoint replaced
  -- through the feature's exchange seam: every purchase is recorded, and
  -- the tokens are numbered so a retry's header can be told from the
  -- first.
  let bought ← IO.mkRef (#[] : Array (String × String × String))
  let tokenSeq ← IO.mkRef 0
  let endpointStatus ← IO.mkRef 200
  SecretsFeature.exchangeFetchRef.set (some (fun method url body => do
    bought.modify (·.push (method, url, body))
    let n ← tokenSeq.modifyGet (fun n => (n + 1, n + 1))
    let st ← endpointStatus.get
    pure (st, "{\"access_token\":\"AT" ++ toString n ++ "\"}")))
  let resetExchange : SIO Unit := do
    bought.set #[]
    tokenSeq.set 0
    endpointStatus.set 200
  let xopts (extra : Array (String × Value) := #[]) : SIO Value := do
    let x ← newMap #[("active", .bool true)]
    for (k, v) in extra do sp x k v
    pure x
  let refreshChain ← memoryOf #[("REFRESH_TOKEN", .str "r1")]
  let xsecrets (providers : Array Value) (x : Value) (extra : Array (String × Value) := #[])
      : SIO Value := do
    secretsOpts providers (#[("name", .str "refresh_token"), ("exchange", x)] ++ extra)

  (do
    resetExchange
    let w ← mkWire
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test/v1/")]
      (← xsecrets #[refreshChain] (← xopts)))
    let err ← attempt c ent
    let b ← bought.get
    check (err.isNone && b.size == 1 && credentialIs (← lastAuth w) "AT1")
      "exchange: the refresh token buys an access token, and the request carries it"
    let shown := if b.isEmpty then "<no purchase>" else b[0]!.1 ++ " " ++ b[0]!.2.1 ++ " " ++ b[0]!.2.2
    check (b.size == 1 && b[0]!.2.1 == "http://api.test/v1/auth/token" && b[0]!.1 == "POST" &&
        hasText b[0]!.2.2 "\"refresh_token\":\"r1\"")
      ("exchange: the purchase POSTs the refresh token to exchange.path under the base (got: " ++ shown ++ ")"))

  (do
    resetExchange
    let w ← mkWire
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts #[("refresh", .str "r-explicit")])))
    let _ ← attempt c ent
    let b ← bought.get
    check (b.size == 1 && hasText b[0]!.2.2 "r-explicit")
      "exchange: an explicit exchange.refresh wins over the chain")

  (do
    resetExchange
    let w ← mkWire
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts)))
    let _ ← attempt c ent
    let _ ← attempt c ent
    let _ ← attempt c ent
    check ((← bought.get).size == 1 && (← w.sent.get) == 3)
      "exchange: one purchase serves many requests")

  (do
    resetExchange
    let w ← mkWire 401.0 (some 200.0)
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts)))
    let err ← attempt c ent
    let auths ← w.auth.get
    check (err.isNone && (← w.sent.get) == 2 && (← bought.get).size == 2 &&
        auths.size == 2 && credentialIs auths[0]! "AT1" && credentialIs auths[1]! "AT2")
      "exchange: a 401 buys another token and retries the SAME request with it"
    check ((← purchases c) == 2.0) "exchange: purchases are counted in track.secrets")

  (do
    resetExchange
    let w ← mkWire 401.0
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts)))
    let _ ← attempt c ent
    check ((← w.sent.get) == 2 && (← bought.get).size == 2)
      "exchange: the retry happens once, not in a loop")

  (do
    resetExchange
    let w ← mkWire 403.0
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts)))
    let _ ← attempt c ent
    check ((← w.sent.get) == 1 && (← bought.get).size == 1)
      "exchange: a status outside exchange.statuses is not an expiry")

  (do
    resetExchange
    let w ← mkWire 403.0 (some 200.0)
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts #[("statuses", ← newList #[.num 403.0])])))
    let _ ← attempt c ent
    check ((← w.sent.get) == 2 && (← bought.get).size == 2)
      "exchange: exchange.statuses is configurable")

  (do
    resetExchange
    let w ← mkWire
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts #[("request", .str "rt"), ("response", .str "at")])))
    -- The endpoint answers `access_token`, which is no longer the field
    -- asked for: the purchase fails and the op refuses with the named field.
    let err ← attempt c ent
    let b ← bought.get
    let shown := (if b.isEmpty then "<no purchase>" else b[0]!.2.2) ++ " / " ++ (err.getD "<no error>")
    check (b.size == 1 && hasText b[0]!.2.2 "\"rt\":\"r1\"" && (← w.sent.get) == 0 &&
        (match err with | some m => hasText m "returned no 'at' field" | none => false))
      ("exchange: the request and response field names are configurable (got: " ++ shown ++ ")"))

  (do
    resetExchange
    let w ← mkWire
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[← memoryOf #[]] (← xopts)))
    let err ← attempt c ent
    check ((← w.sent.get) == 0 && (← bought.get).size == 0 &&
        (match err with | some m => hasText m "secrets: no refresh token" | none => false))
      "exchange: no refresh token anywhere is an error, not an unauthenticated call")

  (do
    resetExchange
    let w ← mkWire 401.0 (some 200.0)
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test"), ("apikey", .str "held-access")]
      (← xsecrets #[refreshChain] (← xopts)))
    let _ ← attempt c ent
    let auths ← w.auth.get
    check (auths.size == 2 && credentialIs auths[0]! "held-access" && credentialIs auths[1]! "AT1" &&
        (← bought.get).size == 1)
      "exchange: an explicit apikey is spent before anything is bought, then falls through on expiry")

  (do
    resetExchange
    let w ← mkWire 401.0
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts)))
    let _ ← attempt c ent
    endpointStatus.set 500
    let w2 ← mkWire 401.0
    let c2 ← liveClient w2 (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts)))
    -- The first purchase (at resolve) fails: the op refuses with the
    -- exchange's message rather than sending unauthenticated.
    let err ← attempt c2 ent
    check ((← w2.sent.get) == 0 &&
        (match err with | some m => hasText m "secrets: token exchange failed: 500" | none => false))
      "exchange: a failing token endpoint at first resolve refuses, never sends"
    -- And a purchase that fails on RETRY surfaces the API's own refusal.
    endpointStatus.set 200
    let w3 ← mkWire 401.0
    let c3 ← liveClient w3 (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts)))
    let _ ← attempt c3 ent
    check ((← w3.sent.get) == 2) "exchange: control - a working endpoint retries once"
    let before ← bought.get
    endpointStatus.set 500
    let w4 ← mkWire 401.0
    let c4 ← liveClient w4 (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts #[("refresh", .str "r-held")])))
    -- resolve: apikey empty, so it buys - and the endpoint is down. Refused.
    let err4 ← attempt c4 ent
    check ((← w4.sent.get) == 0 && err4.isSome && (← bought.get).size == before.size + 1)
      "exchange: a failing token endpoint surfaces the refusal, not a spin")

  (do
    resetExchange
    let w ← mkWire 401.0
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test"), ("auth", .null)]
      (← xsecrets #[refreshChain] (← xopts)))
    -- The op raises on the API's 401; the contract is what reached the wire.
    let _ ← attempt c ent
    check ((← w.sent.get) == 1 && (← lastAuth w).isNone)
      "exchange: auth null suppresses the credential, refusal or not - and never retries")

  (do
    resetExchange
    let w ← mkWire
    let c ← liveClient w (← optsWith #[("base", .str "http://api.test"), ("apikey", .str "PLAINKEY01")]
      (← secretsOpts #[refreshChain] #[("name", .str "refresh_token"),
        ("exchange", ← newMap #[("active", .bool false)])]))
    let _ ← attempt c ent
    check ((← bought.get).size == 0 && (← lastAuth w).isNone == false &&
        credentialIs (← lastAuth w) "PLAINKEY01")
      "exchange: exchange off leaves the feature exactly as it was")

  (do
    resetExchange
    -- TEST MODE BUYS NOTHING: a test-mode client with the exchange on runs
    -- an op without the endpoint ever being called, and the deterministic
    -- token is what the feature recorded as bought.
    let seed ← emptyMap
    let c ← Sdk.testSdk seed (← optsWith #[("base", .str "http://api.test")]
      (← xsecrets #[refreshChain] (← xopts)))
    let err ← attempt c ent
    check (err.isNone && (← bought.get).size == 0 && (← purchases c) == 1.0)
      "exchange: test mode buys nothing and needs no token endpoint")

  SecretsFeature.exchangeFetchRef.set none

def main : IO UInt32 := do
  let sctx ← mkCtx
  let go : SIO Unit := do
    match (← findListEntity) with
    | none => fail "secrets: no entity with a parameterless list op to drive - the suite cannot run"
    | some ent => run ent
  go.run sctx
  let p ← npass.get
  let f ← nfail.get
  IO.println ""
  IO.println s!"secrets: PASS {p}  FAIL {f}"
  if f > 0 || p == 0 then return 1 else return 0
