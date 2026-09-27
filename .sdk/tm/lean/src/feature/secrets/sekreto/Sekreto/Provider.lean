-- VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (lean/src/Sekreto/Provider.lean)
-- Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/-
What a provider is, what its declarative form looks like, and how a
provider kind becomes a voxgig/plugin definition.

A provider answers one question: "do you have this secret?" It returns
the value, or `none` to mean "ask the next one". Nothing else about a
provider is visible to the caller - which is the point: an app reads
`api.token` and never learns whether it came from the environment, a
.env file, HashiCorp Vault, AWS, GCP, Azure or a boru vault.

Two failure shapes, and they are never interchangeable. A store that
does not hold the secret is a MISS (`none`) - the chain carries on. A
store that could not answer - bad credentials, unreachable host, missing
configuration - RAISES: falling through there would reach for a weaker
store without saying so.

THIS MODULE IS THE WHOLE BRIDGE TO voxgig/plugin, and the only file in
the core that imports it. A provider kind is a plugin `Definition`; a
configured provider is an instance of one. What the bridge has to work
around is that plugin's value model carries numbers, strings, lists and
maps - and no pointers - so a `define` cannot hand a Lean closure back
through `inst.export`. See `slotput` below.

A port of typescript/src/provider/support.ts, which is canonical.
-/

import Plugin

import Sekreto.Text
import Sekreto.Json
import Sekreto.Core

namespace Sekreto

/-- A source of secrets: two functions and no lifecycle.

A record of functions rather than a class, so the provider set stays open
- a caller can put its own provider in a chain without this library
knowing the type. `lookup` is in `IO` because the four built-in kinds
already read the environment and the filesystem; `describe` is not,
because it is fixed when the provider is built and the chain calls it at
construction to derive a default store name. -/
structure Provider where
  /-- The value, or `none` if this provider does not have it. A store
  that could not ANSWER throws instead: the two are never the same. -/
  lookup : String → IO (Option String)
  /-- A short description, shown by `Sekreto.sources`. It opens with the
  provider's kind, because `storename` is everything before the first
  `:`. -/
  describe : String

/-- Logging in to a vault instead of being handed a token. `method` is
`kubernetes` or `approle`; `mount` defaults to the method name. -/
structure AuthSpec where
  method : String := ""
  mount : String := ""
  /-- kubernetes: the Vault role to log in as. -/
  role : String := ""
  /-- kubernetes: the service-account JWT itself (tests). -/
  jwt : String := ""
  /-- kubernetes: where the JWT lives; the conventional pod path by
  default. -/
  jwtfile : String := ""
  /-- approle: the role and secret ids. -/
  roleid : String := ""
  secretid : String := ""
  deriving Inhabited

/-- Printed without its credentials.

There is no `deriving Repr` on this structure and there must not be: a
derived printer would put the service-account JWT and the AppRole secret
id into `IO.eprintln s!"bad chain: {specs}"`, which is exactly what
someone writes when a chain will not build. Fields that hold a
credential report whether they are set, never what they are. -/
instance : ToString AuthSpec where
  toString spec :=
    "AuthSpec(method=" ++ spec.method ++ ", mount=" ++ spec.mount ++
    ", role=" ++ spec.role ++ ", jwtfile=" ++ spec.jwtfile ++
    ", roleid=" ++ spec.roleid ++ ", jwt=" ++ setornot spec.jwt ++
    ", secretid=" ++ setornot spec.secretid ++ ")"

/-- The declarative form of a provider, as used in config and in the
shared spec. `kind` names a built-in or a plugin; everything else is that
kind's own.

Every string field defaults to empty rather than being optional: "not
configured" and "configured empty" mean the same thing everywhere in this
library. `kv` is the only number and `values` the only map.

A spec reaches its definition as the plugin instance's OPTIONS:
`optionsof` encodes it with the field names as keys - the spec's own key
names, in every port - and `specof` reads it back. -/
structure ProviderSpec where
  kind : String := ""
  /-- The store name `Sekreto.getfrom` addresses. Defaults to `kind`. -/
  name : String := ""
  «prefix» : String := ""
  /-- dotenv: the file to read. secretspec: the declaration to read. -/
  file : String := ""
  /-- memory: literal values, keyed like environment variables. -/
  values : Pairs String := []
  /-- file: the directory of one-secret-per-file entries. -/
  dir : String := ""
  /-- hashicorp / boru (wire) / gcp / 1password / doppler / infisical:
  the base URL. -/
  addr : String := ""
  /-- hashicorp / boru (wire) / gcp / azure / 1password / doppler /
  infisical: the token. -/
  token : String := ""
  /-- hashicorp / boru (wire): the KV mount (default `secret`). -/
  mount : String := ""
  /-- hashicorp: KV engine version, 1 or 2 (default 2). -/
  kv : Option Nat := none
  /-- hashicorp: Vault Enterprise namespace (X-Vault-Namespace). -/
  vaultnamespace : String := ""
  /-- hashicorp: log in for a token instead of being handed one. -/
  auth : Option AuthSpec := none
  /-- boru / secretspec: the executable to run. -/
  command : String := ""
  /-- secretspec: the profile to read (`--profile`). -/
  profile : String := ""
  /-- secretspec: which of ITS backends to read from (`--provider`).
  Named `backend` here because `provider` already means a sekreto
  provider. -/
  backend : String := ""
  /-- secretspec: the audit reason recorded for the read (`--reason`).
  SecretSpec refuses to read without one. -/
  reason : String := ""
  /-- boru: the namespace qualifying the alias. -/
  «namespace» : String := ""
  /-- boru: the vault home, passed as BORU_HOME. -/
  home : String := ""
  /-- aws: region and credentials; the standard AWS_* variables fill the
  rest. -/
  region : String := ""
  keyid : String := ""
  secret : String := ""
  session : String := ""
  /-- gcp / doppler / infisical: the project, however that store names
  it. -/
  project : String := ""
  /-- azure: the Key Vault name or full URL. 1password: the vault name or
  id. -/
  vault : String := ""
  /-- azure: client-credential login. infisical: universal-auth login. -/
  tenant : String := ""
  clientid : String := ""
  clientsecret : String := ""
  /-- azure: where to log in / where IMDS answers. gcp: the metadata
  server. -/
  loginaddr : String := ""
  imdsaddr : String := ""
  metadataaddr : String := ""
  /-- azure: the Key Vault API version (default 7.4). -/
  apiversion : String := ""
  /-- doppler: the config slug (with `project`). -/
  config : String := ""
  /-- infisical: the environment slug and secret path. -/
  environment : String := ""
  path : String := ""
  deriving Inhabited

/-- Printed without its credentials. See `AuthSpec`: a derived printer
would put the Vault token, the AWS secret access key and the Azure client
secret into whatever formatted it. -/
instance : ToString ProviderSpec where
  toString spec :=
    "ProviderSpec(kind=" ++ spec.kind ++ ", name=" ++ spec.name ++
    ", addr=" ++ spec.addr ++ ", token=" ++ setornot spec.token ++
    ", secret=" ++ setornot spec.secret ++
    ", clientsecret=" ++ setornot spec.clientsecret ++
    ", auth=" ++ (match spec.auth with | none => "none" | some auth => toString auth) ++ ")"

-- ---------------------------------------------------- the local platform

/-- An environment variable, or the empty string. -/
def getenv (name : String) : IO String := do
  return ((← IO.getEnv name).getD "")

/-- What a failure has to say for itself, on one line. Lean's `IO.Error`
renders a file error across two, and a message in this library is one. -/
def why (err : IO.Error) : String :=
  ((toString err).splitOn "\n").headD (toString err)

/-- Does this read failure mean "no secrets here", rather than "I could
not answer"?

Absence is a MISS and the chain carries on; anything else - permission
denied, an unreadable mount, a failing disk - is an ERROR, because
returning a miss there falls silently through to a weaker store.

Asked of the DIRECTORY, not of the file. The obvious spelling, "does the
file exist", is wrong in exactly the case the rule exists for: an
existence predicate answers false for a permission error, and would turn
a locked directory - the canonical unreadable mount - into a miss. A path
whose parent is a plain file really is "no secrets here", and that is
what this asks. -/
private def absentpath (path : String) : IO Bool := do
  match (System.FilePath.mk path).parent with
  | none => return false
  | some dir => return !(← dir.isDir)

/-- The bytes of a file; `none` when there are no secrets there.

`noFileOrDirectory` is ENOENT and is always absence. Anything else is
put to `absentpath`, which answers for ENOTDIR and refuses for everything
else - the refusal carries the underlying failure out to the caller,
which names the provider in the message.

READING A LOCAL FILE IS WHAT THE CORE IS ALLOWED TO DO. It is the line
between a built-in kind and a plugin, so this lives here and not under
`plugins/` - `dotenv` and `file` need it, and so does the one plugin
that reads a pod's service-account token off disk. -/
def readmaybe (path : String) : IO (Option ByteArray) :=
  tryCatch (do return some (← IO.FS.readBinFile path))
    (fun err =>
      match err with
      | .noFileOrDirectory _ _ _ => return none
      | _ => do if ← absentpath path then return none else throw err)

/-- Bytes as text, or the empty string when they are not UTF-8. -/
def astext (bytes : ByteArray) : String := (String.fromUTF8? bytes).getD ""

-- ------------------------------- providers as voxgig/plugin definitions

/-- The export key under which a provider definition publishes the
provider it built. `Sekreto` reads `<ref>/provider` off the host. -/
def PROVIDER_EXPORT : String := "provider"

/-- The voxgig/plugin error code a `SekretoError` travels under when it
is raised inside a definition's `define`.

plugin wraps a code-less error raised by a callback as
`plugin_define_failed`, and keeps an error that already carries a code. A
provider that refuses its own configuration - `kv: 3`, a missing project
- raises a `SekretoError`, and that message is pinned by the spec byte
for byte, so it must come back out of the host exactly as it went in.
`providerplugin` gives it this code on the way in; `Sekreto` turns it
back into a `SekretoError` on the way out. -/
def ERROR_CODE : String := "sekreto_error"

/-- Providers built by a definition's `define`, waiting for the chain to
collect them.

VOXGIG/PLUGIN'S VALUES CARRY NUMBERS AND STRINGS, NOT POINTERS, so a
`define` cannot export the `Provider` it built. It exports the INDEX of
one of these slots instead, and `Sekreto.sekreto` reads the index back
off the host and takes the provider out. The zig port does the same thing
for the same reason.

Module-global, and set for no longer than one construction: `define` puts
a provider in and the chain takes it straight out again, and a chain that
fails part-way drops whatever it left behind. Two threads building chains
at once would race this, and this port - like the plugin port under it -
does not claim to support that. -/
initialize slots : IO.Ref (List (Nat × Provider)) ← IO.mkRef []

/-- The slot number of the next provider built. Monotonic, never reused,
so a stale index can never name a live provider. -/
initialize slotseq : IO.Ref Nat ← IO.mkRef 0

/-- Park a provider, and answer the slot it went into. -/
def slotput (provider : Provider) : IO Nat := do
  let id ← slotseq.modifyGet (fun held => (held, held + 1))
  slots.modify (fun held => held ++ [(id, provider)])
  return id

/-- Take a parked provider out. -/
def slottake (id : Nat) : IO (Option Provider) := do
  let held ← slots.get
  match held.find? (fun entry => id == entry.1) with
  | none => return none
  | some entry =>
    slots.set (held.filter (fun held => id != held.1))
    return some entry.2

/-- Drop every slot from `mark` on: what a chain that could not be
finished left parked. -/
def slotdrop (mark : Nat) : IO Unit := do
  slots.modify (fun held => held.filter (fun entry => entry.1 < mark))

private def putstr (out : Plugin.Value) (key value : String) : Plugin.Value :=
  if value.isEmpty then out else out.set key (.str value)

private def pairsvalue (pairs : Pairs String) : Plugin.Value :=
  pairs.foldl (fun out entry => out.set entry.1 (.str entry.2)) Plugin.Value.vmap

/-- A spec as the options map a plugin instance carries: one key per
field that is set, named as the field is - the spec's own key names in
every port. -/
def optionsof (spec : ProviderSpec) : Plugin.Value :=
  let out := Plugin.Value.vmap
  let out := putstr out "kind" spec.kind
  let out := putstr out "name" spec.name
  let out := putstr out "prefix" spec.«prefix»
  let out := putstr out "file" spec.file
  let out := if spec.values.isEmpty then out else out.set "values" (pairsvalue spec.values)
  let out := putstr out "dir" spec.dir
  let out := putstr out "addr" spec.addr
  let out := putstr out "token" spec.token
  let out := putstr out "mount" spec.mount
  let out := match spec.kv with
    | none => out
    | some held => out.set "kv" (.num (Float.ofNat held))
  let out := putstr out "vaultnamespace" spec.vaultnamespace
  let out := match spec.auth with
    | none => out
    | some auth =>
      let a := Plugin.Value.vmap
      let a := putstr a "method" auth.method
      let a := putstr a "mount" auth.mount
      let a := putstr a "role" auth.role
      let a := putstr a "jwt" auth.jwt
      let a := putstr a "jwtfile" auth.jwtfile
      let a := putstr a "roleid" auth.roleid
      let a := putstr a "secretid" auth.secretid
      out.set "auth" a
  let out := putstr out "command" spec.command
  let out := putstr out "profile" spec.profile
  let out := putstr out "backend" spec.backend
  let out := putstr out "reason" spec.reason
  let out := putstr out "namespace" spec.«namespace»
  let out := putstr out "home" spec.home
  let out := putstr out "region" spec.region
  let out := putstr out "keyid" spec.keyid
  let out := putstr out "secret" spec.secret
  let out := putstr out "session" spec.session
  let out := putstr out "project" spec.project
  let out := putstr out "vault" spec.vault
  let out := putstr out "tenant" spec.tenant
  let out := putstr out "clientid" spec.clientid
  let out := putstr out "clientsecret" spec.clientsecret
  let out := putstr out "loginaddr" spec.loginaddr
  let out := putstr out "imdsaddr" spec.imdsaddr
  let out := putstr out "metadataaddr" spec.metadataaddr
  let out := putstr out "apiversion" spec.apiversion
  let out := putstr out "config" spec.config
  let out := putstr out "environment" spec.environment
  putstr out "path" spec.path

private def strof (options : Plugin.Value) (key : String) : String :=
  (options.get key).asStr

private def pairsof (value : Plugin.Value) : Pairs String :=
  (value.keys).map (fun key => (key, (value.get key).asStr))

/-- The spec a plugin instance's options describe: the inverse of
`optionsof`. -/
def specof (options : Plugin.Value) : ProviderSpec :=
  let field := strof options
  let kv := options.get "kv"
  let authvalue := options.get "auth"
  let auth : Option AuthSpec :=
    if !authvalue.isMap then none
    else
      let afield := strof authvalue
      some {
        method := afield "method", mount := afield "mount", role := afield "role",
        jwt := afield "jwt", jwtfile := afield "jwtfile",
        roleid := afield "roleid", secretid := afield "secretid" }
  {
    kind := field "kind", name := field "name", «prefix» := field "prefix",
    file := field "file", values := pairsof (options.get "values"), dir := field "dir",
    addr := field "addr", token := field "token", mount := field "mount",
    kv := if kv.isNum then some kv.asNum.toUInt64.toNat else none,
    vaultnamespace := field "vaultnamespace", auth := auth,
    command := field "command", profile := field "profile", backend := field "backend",
    reason := field "reason", «namespace» := field "namespace", home := field "home",
    region := field "region", keyid := field "keyid", secret := field "secret",
    session := field "session", project := field "project", vault := field "vault",
    tenant := field "tenant", clientid := field "clientid",
    clientsecret := field "clientsecret", loginaddr := field "loginaddr",
    imdsaddr := field "imdsaddr", metadataaddr := field "metadataaddr",
    apiversion := field "apiversion", config := field "config",
    environment := field "environment", path := field "path" }

/-- A provider kind, as a voxgig/plugin definition.

The definition's `name` is the `kind` a `ProviderSpec` names; its
`define` reads the spec as the instance's options, builds the provider
with `make`, and exports the slot it parked it in. Nothing runs at
`activate`: a provider opens nothing until its first lookup, so there is
nothing to capture - a provider that does hold a resource acquires it
there and lets the instance scope unwind it.

Every built-in and every plugin is made this way, so a custom provider
kind is one call:

    providerplugin "mystore" (fun spec => mystoreprovider spec.addr)

WHICH FAILURES ARE SEKRETO'S IS DECIDED BY THE CONSTRUCTOR OF THE ERROR,
not by guessing at its text. A `userError` raised by `make` is taken as a
provider refusing its own configuration and comes back out under
`ERROR_CODE` byte for byte; every other `IO.Error` - a missing file, a
permission denial - is not sekreto's

AND THE LIMIT OF THAT, STATED RATHER THAN GLOSSED: `IO.userError` is not
sekreto's alone. It is Lean's ordinary message-only error, and
`IO.ofExcept` on any `Except String _` produces one, so a `make` that
reaches a library raising `userError` for its own reasons has that error
taken as sekreto's - the message survives byte for byte, but the host's
framing and the instance ref are lost. Canonical checks
`err instanceof SekretoError` and rethrows everything else; `IO.Error` is
a closed inductive with no subclass to check, so Lean cannot do the same.
Every kind this library ships raises through `Sekreto.fail`, so the
shipped surface is exact; only a consumer's own `providerplugin` can reach
the gap. Measured: a definition whose `make` is
`IO.ofExcept (Except.error "connection refused by libfoo")` comes back as
a bare SekretoError rather than the host's report of it
to rewrite and surfaces as the host reports it, naming the instance. -/
def providerplugin (kind : String) (make : ProviderSpec → IO Provider) : Plugin.Definition := {
  name := kind
  define := some (fun inst => do
    let options ← inst.getOptions
    let made ← (tryCatch (do return Except.ok (← make (specof options)))
      (fun (err : IO.Error) => return Except.error err) : IO _)
    match made with
    | .error (.userError message) =>
      Plugin.raise ERROR_CODE message
        ((Plugin.Value.vmap.set "ref" (.str inst.ref)).set "cause" (.str message))
    | .error other => Plugin.raise "plugin_bare" (why other)
    | .ok provider =>
      let id ← slotput provider
      inst.exportValue PROVIDER_EXPORT (.num (Float.ofNat id))) }

end Sekreto
