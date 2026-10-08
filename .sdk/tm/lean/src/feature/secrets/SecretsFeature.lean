/- Univec SDK secrets feature: the API credential through a vendored
   @voxgig/sekreto provider chain, and the access-token exchange some APIs
   require on top of it. The lean port of tm/go/feature/secrets_feature.go -
   same contract, seam for seam, in this target's idiom.

   The SDK's `apikey` option keeps exactly its old meaning: an explicit
   credential given in code. This feature makes it ONE SOURCE among several
   rather than the only one: when active, the credential is resolved through
   a sekreto chain in which the explicit option (when set) is the FIRST
   provider - a `memory` store named `options` - so an explicit value always
   wins, by sekreto's own first-hit rule rather than by special-case logic.

   WHERE THE SEAM IS. lean has ONE wire path: every entity operation crosses
   `SdkRuntime.runOp`, which builds the request and hands it to the client's
   fetcher chain (there is no raw direct()/graphql() client method - graphql
   is a point kind inside the pipeline). So this feature wraps the transport
   (`setFetcher`), exactly as go does, and resolves THERE: the wrapper is the
   sole writer of the authorization header for a chain-resolved credential
   (prepareAuth wrote it from `options.apikey`; the wrapper rewrites it from
   the resolved value with the same construction and the same `auth: null`
   suppression), and nothing is ever written back into the shared options
   map.

   MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
   op proceeds, unauthenticated if nothing else supplies a credential. A
   provider ERROR must FAIL the op: a broken vault never degrades into an
   unauthenticated request. The wrapper REFUSES TO SEND while the chain
   could not be built (a construction failure, or a malformed `providers`
   entry - never dropped, never shortened) and while the last resolution
   stands failed. Fail-closed at the one seam every request must pass, and
   WRAPPED BEFORE BUILT, so an init failure is closed rather than open.

   EXCHANGE: what the chain resolves is then a REFRESH token, which buys a
   short-lived ACCESS token from `exchange.path` (relative to options.base);
   the access token is what every request carries, and a response status in
   `exchange.statuses` (401) buys another and retries the same request once.
   Test mode buys nothing and answers with the deterministic
   `"test-" ++ exchange.response`.

   Concurrency is far simpler than go's: SIO is single-threaded, so the
   mutex, the shared in-flight resolution and the shared purchase collapse
   to plain IO.Refs. -/

import VoxgigStruct
import SdkJson
import SdkUtility
import SdkFeature
import Sekreto
-- #SecretsPluginImports

open VoxgigStruct
open SdkFeature

namespace SecretsFeature

def gp := SdkUtility.gp
def sp := SdkUtility.sp
def gpS := SdkUtility.gpS

/-- The plugin DEFINITIONS the model selected for this feature - the
    `def: lean:` entries of the active plugin groups, filled by Main_lean
    (Config_go's core.FeaturePlugins, one language over). Upstream sekreto's
    contract since the registry was retired: a kind not passed in `plugins`
    is unknown to this Sekreto, so the model's choice of plugin groups IS
    the SDK's provider vocabulary. Empty when no group is on: the four
    built-in kinds (env, memory, dotenv, file) are always there. -/
def featurePlugins : List Plugin.Definition := [
  -- #SecretsPluginDefs
  ]

/-- The exchange, normalised once at init. -/
structure Exchange where
  path : String
  method : String
  request : String
  response : String
  statuses : Array Float
  retries : Nat

/-- One token-exchange round-trip: method, url, JSON body -> (status, body).

    THE SEAM A TEST REPLACES. lean's options cannot hold a closure, so the
    `system.fetch` override every dynamically typed port honours for the
    exchange is a module-level slot here instead; `none` means the raw
    transport below. -/
abbrev ExchangeFetch := String → String → String → IO (Nat × String)

initialize exchangeFetchRef : IO.Ref (Option ExchangeFetch) ← IO.mkRef none

/-- The token-exchange transport of last resort: a curl shell-out, local to
    this feature. Deliberately NOT SdkRuntime.curlFetch (SdkFeatures imports
    this module and SdkRuntime imports SdkFeatures, so that is a cycle) and
    deliberately NOT the SDK transport: the transport is what this feature
    wraps, so sending the token request back through it would recurse on the
    first expiry, and would route the exchange through the test mock, which
    knows nothing about it. Same shape as go's rawExchangeFetch. -/
def rawExchangeFetch : ExchangeFetch := fun method url body => do
  let out ← IO.Process.output {
    cmd := "curl",
    args := #["-s", "-w", "\n%{http_code}", "--max-time", "30", "-X", method,
              "-H", "content-type: application/json", "-d", body, url] }
  if out.exitCode != 0 then
    throw (IO.userError s!"secrets: token exchange transport failed ({out.exitCode}): {out.stderr}")
  let lines := out.stdout.splitOn "\n"
  let status := ((lines.getLastD "0").toNat?).getD 0
  pure (status, String.intercalate "\n" lines.dropLast)

-- ---------------------------------------------------------------------------
-- option readers
-- ---------------------------------------------------------------------------

def optBool (opts : Value) (k : String) (d : Bool) : SIO Bool := do
  match (← gp opts k) with
  | .bool b => pure b
  | _ => pure d

def optNumList (opts : Value) (k : String) (d : Array Float) : SIO (Array Float) := do
  match (← gp opts k) with
  | .list i =>
    let its ← listItems i
    let nums := its.filterMap (fun v => match v with | .num n => some n | _ => none)
    pure (if nums.isEmpty then d else nums)
  | _ => pure d

/-- `s` without its trailing `/`s, and without its leading ones: the base
    and the token path are joined with exactly one. -/
partial def trimEndSlashes (s : String) : String :=
  if s.endsWith "/" then trimEndSlashes (Sekreto.dropsuffix s "/") else s

partial def trimStartSlashes (s : String) : String :=
  if s.startsWith "/" then trimStartSlashes (s.drop 1).toString else s

/-- A value, for a refusal message. Never a credential: this is only ever
    applied to a `providers` entry that is NOT a spec. -/
def render (v : Value) : SIO String := do
  match v with
  | .str s => pure s
  | .num n => pure (toString n)
  | .bool b => pure (toString b)
  | .null => pure "null"
  | .noval => pure "undefined"
  | _ => jsonify v

/-- A `providers` entry, as sekreto's declarative ProviderSpec: every field
    the spec knows, read by its own name. Unknown keys are ignored, as every
    port's `specof` ignores them. -/
def specOfValue (v : Value) : SIO Sekreto.ProviderSpec := do
  let f := fun (k : String) => gpS v k
  let valuesV ← gp v "values"
  let mut values : Sekreto.Pairs String := []
  match valuesV with
  | .map _ =>
    for k in (← keysof valuesV) do
      values := values ++ [(k, SdkUtility.vs (← gp valuesV k))]
  | _ => pure ()
  let kv ← match (← gp v "kv") with
    | .num n => pure (some (fToInt n).toNat)
    | _ => pure none
  let authV ← gp v "auth"
  let auth ← match authV with
    | .map _ => pure (some ({
        method := ← gpS authV "method", mount := ← gpS authV "mount",
        role := ← gpS authV "role", jwt := ← gpS authV "jwt",
        jwtfile := ← gpS authV "jwtfile", roleid := ← gpS authV "roleid",
        secretid := ← gpS authV "secretid" } : Sekreto.AuthSpec))
    | _ => pure none
  pure {
    kind := ← f "kind", name := ← f "name", «prefix» := ← f "prefix",
    file := ← f "file", values := values, dir := ← f "dir",
    addr := ← f "addr", token := ← f "token", mount := ← f "mount",
    kv := kv, vaultnamespace := ← f "vaultnamespace", auth := auth,
    command := ← f "command", profile := ← f "profile", backend := ← f "backend",
    reason := ← f "reason", «namespace» := ← f "namespace", home := ← f "home",
    region := ← f "region", keyid := ← f "keyid", secret := ← f "secret",
    session := ← f "session", project := ← f "project", vault := ← f "vault",
    tenant := ← f "tenant", clientid := ← f "clientid",
    clientsecret := ← f "clientsecret", loginaddr := ← f "loginaddr",
    imdsaddr := ← f "imdsaddr", metadataaddr := ← f "metadataaddr",
    apiversion := ← f "apiversion", config := ← f "config",
    environment := ← f "environment", path := ← f "path" }

/-- The wording every port's Sekreto constructor uses for a `providers`
    entry that is neither a provider nor a spec (a bare kind name, a null,
    a number). lean's Options.providers is a typed list, so there is
    nothing to push such an entry through - the feature refuses with the
    library's own message here, the way go does. -/
def NOTAPROVIDER : String := "sekreto: not a provider or a provider spec: "

/-- The refusal a transport wrapper answers with: no response, an error the
    pipeline raises with sekreto's own message. -/
def refuse (msg : String) : SIO (Value × Option Value) := do
  pure (.noval, some (← SdkUtility.mkErr "secrets_refused" msg))

/-- Rewrite THIS request's authorization header from the resolved credential:
    the same construction and the same `auth: null` suppression prepareAuth
    applies to the options apikey, so the two cannot drift. `ctx` is the
    operation context (options and config), `fetchdef` the outgoing
    request. -/
def reauth (ctx fetchdef : Value) (token : String) : SIO Unit := do
  let headers ← gp fetchdef "headers"
  match headers with
  | .map _ =>
    let options ← gp ctx "options"
    -- `auth: null` is the documented way to send NO credential. getpropRaw
    -- is the only reader that tells a stored null from an absent key - and
    -- absence is the ordinary case here, since lean's client never runs
    -- options through an optspec (see SdkUtility.prepareAuth).
    let authRaw ← getpropRaw options "auth"
    if authRaw == .null then
      SdkUtility.dp headers "authorization"
    else
      let pfx ← SdkUtility.authPrefix ctx
      sp headers "authorization" (.str (if pfx != "" then pfx ++ " " ++ token else token))
  | _ => pure ()

/-- Is this response's status one the exchange treats as "token spent"? -/
def spent (x : Exchange) (res : Value) : SIO Bool := do
  match (← gp res "status") with
  | .num st => pure (x.statuses.contains st)
  | _ => pure false

-- ---------------------------------------------------------------------------
-- the feature
-- ---------------------------------------------------------------------------

/-- The constructor `SdkFeatures.makeFeature` calls for `"secrets"`. All state
    is per client, in the refs this closes over. -/
def secretsFeature : SIO Feature := do
  -- The init-failure gate: a construction failure or a malformed
  -- `providers` entry. While set, the transport REFUSES to send.
  let initerrR ← IO.mkRef (none : Option String)
  let sekR ← IO.mkRef (none : Option Sekreto)
  -- The RESOLVED credential, held here and injected per request - never
  -- written into the options map (go's structural rule, kept for parity).
  let credR ← IO.mkRef ""
  -- A settled SUCCESS stands while caching is on; a failure never settles,
  -- so a transient outage cannot poison the client.
  let settledR ← IO.mkRef false
  let refreshR ← IO.mkRef ""
  let exchangeR ← IO.mkRef (none : Option Exchange)
  let nameR ← IO.mkRef "apikey"
  let cacheR ← IO.mkRef true

  -- Observable state, in the client's `track.secrets` bucket like every
  -- other lean feature: how many tokens were bought, and the init failure
  -- (a message). Never a credential.
  let bucket (client : Value) : SIO Value :=
    trackBucket client "secrets" (newMap #[("purchases", .num 0.0)])

  let buy (client : Value) : SIO (Except String String) := do
    match ← exchangeR.get with
    | none => pure (.error "secrets: exchange is not active")
    | some x =>
      -- TEST MODE BUYS NOTHING: no request leaves the process, and the
      -- suite needs no token endpoint. A deterministic, obviously-fake
      -- token instead.
      if (← gpS client "mode") != "live" then
        let token := "test-" ++ x.response
        credR.set token
        SdkUtility.cleanAddOptions (← gp client "options") (.str token)
        bumpNum (← bucket client) "purchases" 1.0
        return .ok token
      let refresh ← refreshR.get
      if refresh == "" then
        return .error ("secrets: no refresh token: the provider chain has no '" ++
          (← nameR.get) ++ "', and feature.secrets.exchange.refresh is unset")
      let options ← gp client "options"
      let config ← gp client "config"
      let userBase ← gpS options "base"
      let base ← if userBase != "" then pure userBase
                 else gpS (← gp config "options") "base"
      let url := trimEndSlashes base ++ "/" ++ trimStartSlashes x.path
      -- The body is SERIALISED, never concatenated: a refresh token carrying
      -- a quote or a backslash must arrive as that literal value. Compact
      -- (jsonify's default is a 2-space pretty print).
      let body ← jsonify (← newMap #[(x.request, .str refresh)])
        (← newMap #[("indent", .num 0.0)])
      let fetch := (← exchangeFetchRef.get).getD rawExchangeFetch
      bumpNum (← bucket client) "purchases" 1.0
      let answered ← try (do pure (Except.ok (← fetch x.method url body)))
        catch e => pure (Except.error (Sekreto.why e))
      match answered with
      | .error msg => return .error msg
      | .ok (status, text) =>
        if status < 200 || status >= 300 then
          return .error ("secrets: token exchange failed: " ++ toString status ++ " from " ++ url)
        let parsed ← try (do pure (some (← SdkJson.jsonRead text))) catch _ => pure none
        let token ← match parsed with
          | some json => gpS json x.response
          | none => pure ""
        if token == "" then
          return .error ("secrets: token exchange returned no '" ++ x.response ++
            "' field from " ++ url)
        credR.set token
        SdkUtility.cleanAddOptions (← gp client "options") (.str token)
        return .ok token

  -- One resolution. A provider ERROR answers `some message` and the
  -- transport refuses with it; a MISS answers `none` and the op proceeds.
  let resolve (client : Value) : SIO (Option String) := do
    if (← cacheR.get) && (← settledR.get) then return none
    match ← sekR.get with
    | none => return none
    | some sek =>
      let name ← nameR.get
      let found : Except String (Option String) ← try (do pure (Except.ok (← sek.tryget name)))
        catch e => pure (Except.error (Sekreto.why e))
      match found with
      | .error msg => return some msg
      | .ok found =>
        -- Every value this feature resolves or buys is a secret the SDK
        -- handles: registered so no diagnostic can carry it.
        if let some f := found then
          SdkUtility.cleanAddOptions (← gp client "options") (.str f)
        match ← exchangeR.get with
        | none =>
          -- An UNCACHED miss after an earlier hit is a revocation: the
          -- chain now says no provider has the secret, so the resolved
          -- value must not keep going out on the wire. (An explicit
          -- apikey OPTION is never lost here - it seats FIRST in the chain
          -- as a memory provider, so the chain HITS while one is set.)
          credR.set (found.getD "")
          settledR.set true
          return none
        | some _ =>
          -- Exchanging: the chain resolved the REFRESH token. A miss is
          -- not fatal here - an explicit `apikey` may already hold a usable
          -- access token, and the API is what gets to say whether it does.
          refreshR.set (found.getD "")
          if (← credR.get) == "" then
            credR.set (← gpS (← gp client "options") "apikey")
          if (← credR.get) != "" then
            settledR.set true
            return none
          match ← buy client with
          | .ok _ =>
            settledR.set true
            return none
          | .error msg => return some msg

  -- Buy a token and try the request again when the API says the current
  -- one is spent. The retry rewrites the authorization header IN PLACE.
  let withrefresh (x : Exchange) (ctx : Value) (u : String) (f : Value)
      (inner : Fetcher) : SIO (Value × Option Value) := do
    -- `auth: null` is a deliberately unauthenticated request: a refusal of
    -- it is not an expired token, and retrying would transmit exactly the
    -- credential the caller suppressed.
    let options ← gp ctx "options"
    if (← getpropRaw options "auth") == .null then return ← inner ctx u f
    let client ← clientOf ctx
    let mut attempt := 0
    let mut out ← inner ctx u f
    -- The credential each attempt went out with, captured before it left:
    -- it is what tells a stale refusal apart from a fresh one.
    let mut used ← credR.get
    while attempt < x.retries do
      if out.2.isSome || !(← spent x out.1) then break
      -- Another request may have bought a token while this one was in
      -- flight: spend what is current before buying.
      let current ← credR.get
      let mut token := ""
      if current != "" && current != used then
        token := current
      else
        match ← buy client with
        | .ok bought => token := bought
        | .error _ =>
          -- The purchase failed: answer with the API's own refusal rather
          -- than this one - the caller asked for data, and the refusal is
          -- the more useful of the two.
          return out
      reauth ctx f token
      used := token
      out ← inner ctx u f
      attempt := attempt + 1
    pure out

  -- The wrapper: fail-closed at the ONE seam every wire path crosses.
  let transport (ctx : Value) (u : String) (f : Value) (inner : Fetcher)
      : SIO (Value × Option Value) := do
    match ← initerrR.get with
    | some msg => refuse msg
    | none =>
      let client ← clientOf ctx
      match ← resolve client with
      | some msg => refuse msg
      | none =>
        let cred ← credR.get
        if cred != "" then reauth ctx f cred
        match ← exchangeR.get with
        | none => inner ctx u f
        | some x => withrefresh x ctx u f inner

  pure { name := "secrets", version := "0.1.0"
       , init := fun ctx opts => do
           if !(← optActive opts) then return ()
           let client ← clientOf ctx
           let options ← gp client "options"

           let name ← optStr opts "name" "apikey"
           nameR.set name
           cacheR.set (← optBool opts "cache" true)

           -- The exchange, normalised once. `none` when off, so every later
           -- decision is a match on it.
           let xopts ← gp opts "exchange"
           let xactive ← match xopts with
             | .map _ => optActive xopts
             | _ => pure false
           if xactive then
             exchangeR.set (some {
               path := ← optStr xopts "path" "auth/token",
               method := ← optStr xopts "method" "POST",
               request := ← optStr xopts "request" "refresh_token",
               response := ← optStr xopts "response" "access_token",
               statuses := ← optNumList xopts "statuses" #[401.0],
               retries := (← optInt xopts "retries" 1).toNat })

           -- The explicit credential, when set, is the FIRST store in the
           -- chain. WHICH option that is depends on the exchange: without
           -- one the secret IS the credential the transport sends, so
           -- `apikey`; with one the secret is a REFRESH token and `apikey`
           -- is a starting access token, so the seat is `exchange.refresh`.
           let explicit ← if xactive then gpS xopts "refresh" else gpS options "apikey"
           let mut specs : List Sekreto.ProviderSpec := []
           if explicit != "" then
             SdkUtility.cleanAddOptions options (.str explicit)
             match Sekreto.envkey name with
             | .ok key =>
               specs := specs ++ [{ kind := "memory", name := "options", values := [(key, explicit)] }]
             | .error msg => initerrR.set (some msg)

           -- The configured chain. Every entry must be a spec map: lean's
           -- Value cannot carry a live Provider (a closure), so ts's
           -- "provider objects accepted verbatim" has no lean form; a
           -- custom kind is a plugin definition instead. ANYTHING that is
           -- not a map - a bare kind name, a null, a number - is REFUSED
           -- with sekreto's own wording, never dropped: a dropped entry
           -- shortens the chain, and a shortened chain sends ordinary
           -- unauthenticated requests, the exact fail-open the gate
           -- exists to prevent.
           match (← gp opts "providers") with
           | .list i =>
             for p in (← listItems i) do
               match p with
               | .map _ => specs := specs ++ [← specOfValue p]
               | other => initerrR.set (some (NOTAPROVIDER ++ (← render other)))
           | .noval => pure ()
           | other => initerrR.set (some (NOTAPROVIDER ++ (← render other)))

           -- WRAP FIRST. The gate below reads the refs at request time, so
           -- the order is not load-bearing for a single-threaded runtime -
           -- but it is the rule every port follows, and it is what makes
           -- an init failure fail CLOSED rather than leave the transport
           -- unwrapped.
           let inner ← getFetcher client
           setFetcher client fun c u f => transport c u f inner

           -- BUILD SECOND. Eager, and it may refuse - an unknown kind, an
           -- unusable store name - in which case the gate refuses every
           -- request with the constructor's own message. Construction
           -- contacts nothing; the first network call is the first lookup.
           if (← initerrR.get).isNone then
             let built ← try (do
                 pure (Except.ok (← Sekreto.sekreto {
                   providers := specs, plugins := featurePlugins,
                   cache := ← cacheR.get })))
               catch e => pure (Except.error (Sekreto.why e))
             match built with
             | .ok s => sekR.set (some s)
             | .error msg => initerrR.set (some msg)

           match ← initerrR.get with
           | some m => sp (← bucket client) "initerr" (.str m)
           | none => pure ()
       }

end SecretsFeature
