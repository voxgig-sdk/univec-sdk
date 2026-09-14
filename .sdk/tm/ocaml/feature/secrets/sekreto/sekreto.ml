(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/src/sekreto.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* sekreto: one interface for secrets, wherever they live.

   A Sekreto is an ordered chain of providers. `get` asks each in turn and
   returns the first hit, so an app can be configured from environment
   variables in development and a vault in production without changing a
   line of its own code.

   A provider answers one question: "do you have this secret?" It answers
   with the value, or None to mean "ask the next one". Nothing else about a
   provider is visible to the caller - which is the point: an app reads
   `api.token` and never learns whether it came from the environment, a
   .env file, HashiCorp Vault or a boru vault.

   THE CHAIN IS A voxgig/plugin HOST. Each spec'd provider is an instance
   on it, addressed by name and tag - `hashicorp` for a store named after
   its kind, `hashicorp$prod` otherwise - so `Sekreto.host` reads like the
   chain. Only four kinds are built in: `env`, `memory`, `dotenv` and
   `file`, the ones that read at most a local file. Every kind that opens a
   socket, signs a request or spawns a process lives under `plugins/`, and
   a chain may name one only if the calling project handed it to
   `~plugins`. That is what keeps a chain of built-ins free of TLS, of AWS
   request signing and of seven HTTP vault clients.

   A port of typescript/src/Sekreto.ts, which is canonical. *)

module V = Value
open Secret

(* ---- the core surface, under its canonical names ---------------------

   `Secret` and `Provider` are separate modules only because OCaml compiles
   a module before anything that uses it: the facade needs the four
   built-in kinds, which need the name functions and the error. A caller
   writes `Sekreto.envkey` and never has to know. *)

exception Sekreto_error = Secret.Sekreto_error

type provider = Secret.provider = {
  lookup : string -> string option;
  describe : unit -> string;
}

type vaultref = Secret.vaultref = { path : string; field : string }

let fail = Secret.fail
let dropsuffix = Secret.dropsuffix
let segments = Secret.segments
let validsegment = Secret.validsegment
let validname = Secret.validname
let checkname = Secret.checkname
let upper = Secret.upper
let envkey = Secret.envkey
let vaultref = Secret.vaultref
let flatname = Secret.flatname
let awsparam = Secret.awsparam
let unescape = Secret.unescape
let trim = Secret.trim
let assocset = Secret.assocset
let parsedotenv = Secret.parsedotenv
let replaceall = Secret.replaceall
let redact = Secret.redact
let storename = Secret.storename
let findsub = Secret.findsub
let splitfirst = Secret.splitfirst

(* A plugin error carries a parseable message and no printer of its own, so
   a host that catches one - the CLI, the conformance runner - would read
   `Types.Plugin_error(_)` instead of the diagnostic. Registered here
   because this is the module every consumer already links. *)
let () =
  Printexc.register_printer (function
    | Types.Plugin_error err -> Some err.Types.message
    | _ -> None)

(* ---- refusals that name the fix -------------------------------------- *)

(* The message for a kind the catalog does not hold.

   A kind sekreto has never heard of is a typo; a kind that exists as a
   plugin but was not passed in is the split working as designed and
   telling you what to pass. Collapsing the two was the first thing that
   made the split confusing to use. *)
let unknownkind (kind : string) (catalog : Defs.catalog) : string =
  let available =
    String.concat ", " (List.map V.as_str (V.items (Catalog.names catalog)))
  in
  "sekreto: unknown provider kind: " ^ kind ^ " (available: " ^ available ^ ")"
  ^
  if List.mem kind Provider.pluginkinds then
    " - " ^ kind ^ " is a sekreto plugin, not built in: pass it in the plugins option"
  else ""

(* A Sekreto_error that crossed the plugin boundary comes back out as
   itself, byte for byte. Anything else is not sekreto's to rewrite: it
   surfaces as the host reports it, naming the instance. *)
let unwrap (err : exn) : exn =
  match err with
  | Types.Plugin_error report
    when Provider.error_code = report.Types.code
         && V.is_str (V.get report.Types.details "cause") ->
    Sekreto_error (V.as_str (V.get report.Types.details "cause"))
  | other -> other

(* ---- the facade ------------------------------------------------------ *)

(* One provider in the chain, under the store name it answers to, and the
   ref of the plugin instance that built it - `""` for a live provider
   handed in directly, which no instance backs. *)
type entry = { store : string; eref : string; eprovider : provider }

type cached = { cstore : string; cname : string; cvalue : string }

type t = {
  (* The voxgig/plugin host every spec'd provider is an instance of. Read
     it for introspection - `Host.list` names each instance and its status
     - and nothing on it advances the chain. *)
  thost : Defs.host;
  (* The definitions this Sekreto can build: the built-ins, then whatever
     `~plugins` handed in. *)
  tcatalog : Defs.catalog;
  mutable entries : entry list;
  (* A list, not a map: the store a value came from stays attached, and
     redaction order does not vary between runs. *)
  mutable cache : cached list;
  (* Every value ever resolved, for `redacttext`. Kept independently of the
     read cache so that redaction still works when caching is off -
     otherwise an uncached Sekreto would silently disable redaction and leak
     secrets to logs. Append-only for the object's life: neither `refresh`
     nor `close` clears it. Held reversed, and reversed back on read. *)
  mutable seen : string list;
  docache : bool;
}

let host (self : t) : Defs.host = self.thost
let catalog (self : t) : Defs.catalog = self.tcatalog

(* Built-ins first, then the plugins, into one catalog: a plugin that names
   a built-in kind replaces it, which is how a host substitutes an
   implementation and never an accident, because the four names are
   documented. *)
let makecatalog (plugins : Defs.definition list) : Defs.catalog =
  let catalog = Catalog.makecatalog () in
  List.iter (Catalog.add catalog) (Provider.builtins () @ plugins);
  catalog

let empty (plugins : Defs.definition list) (cache : bool) : t =
  let catalog = makecatalog plugins in
  {
    thost = Host.makehost { Defs.nohostoptions with ocatalog = Some catalog };
    tcatalog = catalog;
    entries = [];
    cache = [];
    seen = [];
    docache = cache;
  }

(* One chain entry, as a plugin instance.

   The instance is `kind` for a store named after its kind and `kind$store`
   otherwise, so the host reads like the chain. A store name already taken
   gets a numbered tag from the host instead, because two providers MAY
   share a store name - a directed read walks both - and an instance ref
   may not. *)
let declare (self : t) (spec : Provider.spec) : entry =
  let kind = spec.Provider.kind in

  if not (Catalog.has self.tcatalog kind) then fail (unknownkind kind self.tcatalog);

  let store = if "" = spec.Provider.name then kind else spec.Provider.name in

  if not (Ref.checktag (V.vstr store)) then fail ("sekreto: invalid store name: " ^ store);

  let wanted = if store = kind then kind else Ref.formatref (V.vstr kind) (V.vstr store) in
  let iref =
    if None = Host.instance self.thost wanted then wanted else Host.autotag self.thost kind
  in

  (* `load` runs the definition's `define`, which builds the provider from
     the spec; `activate` takes the instance live. Nothing is contacted by
     either: a provider opens nothing until its first lookup. *)
  (try
     ignore (Host.load self.thost iref { Defs.nospec with soptions = Some (Provider.optionsof spec) });
     ignore (Host.activate self.thost iref)
   with err -> raise (unwrap err));

  let handle =
    match Host.exports self.thost (iref ^ "/" ^ Provider.provider_export) with
    | Some held when V.is_num held -> int_of_float (V.as_num held)
    | _ -> 0
  in

  match Provider.providerof handle with
  | Some made -> { store; eref = iref; eprovider = made }
  (* A definition that loads, activates and exports no provider is not a
     provider plugin at all, and saying so by name is more use than a
     missing-export error from the host. *)
  | None -> fail ("sekreto: plugin " ^ kind ^ " exported no provider")

(* Build a chain from live providers. `names` is positional; an entry left
   empty falls back to the provider's kind. No plugin instance backs any of
   them, so the host stays empty. Construction contacts nothing - the first
   network call is the first lookup. *)
let make ?(names = []) ?(cache = true) (providers : provider list) : t =
  let self = empty [] cache in
  self.entries <-
    List.mapi
      (fun index made ->
        let named = match List.nth_opt names index with Some n -> n | None -> "" in
        { store = (if "" <> named then named else storename made); eref = ""; eprovider = made })
      providers;
  self

(* Build a chain from declarative provider specs - the same shape the
   shared spec and an app's config file use.

   `~plugins` is the whole loading mechanism: static, explicit, and a list
   handed to a constructor rather than a side effect of importing. A kind
   that is not built in and was not passed here cannot be built, and the
   refusal says so. *)
let sekreto ?(cache = true) ?(plugins = []) (specs : Provider.spec list) : t =
  let self = empty plugins cache in

  match List.map (declare self) specs with
  | entries ->
    self.entries <- entries;
    self
  | exception err ->
    (* Whatever was declared before the refusal is torn down, so a chain
       that never came into being leaves no live instance and no stashed
       provider behind. Each definition's `close` hands its own handle
       back, so nothing here has to know which were taken. *)
    (try Host.close self.thost with _ -> ());
    raise err

(* The single path both readers share. The name is validated FIRST, before
   the cache and before the first provider is asked. *)
let resolve (self : t) (store : string) (name : string) (useentries : entry list) :
    string option =
  ignore (checkname name);

  let hit =
    if self.docache then
      List.find_opt (fun c -> store = c.cstore && name = c.cname) self.cache
    else None
  in

  match hit with
  | Some c -> Some c.cvalue
  | None ->
    let rec walk = function
      | [] -> None
      | e :: rest -> (
        (* The empty string is a hit; None and only None is a miss. *)
        match e.eprovider.lookup name with Some value -> Some value | None -> walk rest)
    in
    let found = walk useentries in
    (match found with
    | Some value ->
      if self.docache then self.cache <- self.cache @ [ { cstore = store; cname = name; cvalue = value } ];
      self.seen <- value :: self.seen
    (* Misses are never cached. *)
    | None -> ());
    found

(* The secret, or None if no provider has it. Named `tryget` because `try`
   is an OCaml keyword. *)
let tryget (self : t) (name : string) : string option = resolve self "" name self.entries

(* The secret, or a Sekreto_error if no provider has it. *)
let get (self : t) (name : string) : string =
  match tryget self name with
  | Some value -> value
  | None -> fail ("sekreto: unknown secret: " ^ name)

(* The secret from one named store, or None if that store does not have it.

   Naming a store that is not in the chain is an error, not a miss:
   `tryget` already means "this store may not have it", so it cannot also
   mean "this store may not exist" without hiding a typo. The refusal comes
   before the name is validated. *)
let tryfrom (self : t) (store : string) (name : string) : string option =
  let matching = List.filter (fun e -> store = e.store) self.entries in
  if [] = matching then fail ("sekreto: unknown store: " ^ store);
  resolve self store name matching

let getfrom (self : t) (store : string) (name : string) : string =
  match tryfrom self store name with
  | Some value -> value
  | None -> fail ("sekreto: unknown secret: " ^ store ^ ":" ^ name)

let has (self : t) (name : string) : bool = None <> tryget self name
let hasin (self : t) (store : string) (name : string) : bool = None <> tryfrom self store name

(* Every named secret at once. Missing ones are an error. *)
let all (self : t) (names : string list) : (string * string) list =
  List.map (fun name -> (name, get self name)) names

(* A description of each provider, in resolution order, repeats kept. *)
let sources (self : t) : string list = List.map (fun e -> e.eprovider.describe ()) self.entries

(* The name of each store `getfrom` can address, in resolution order and
   without repeats. *)
let stores (self : t) : string list =
  let rec dedupe seen = function
    | [] -> []
    | head :: rest ->
      if List.mem head seen then dedupe seen rest else head :: dedupe (head :: seen) rest
  in
  dedupe [] (List.map (fun e -> e.store) self.entries)

(* Replace every value this Sekreto has resolved with `[redacted]`. Works
   whether or not caching is on. *)
let redacttext (self : t) (text : string) : string = redact text (List.rev self.seen)

(* Drop cached values, so the next `get` asks the providers again. The
   redaction history is not touched. *)
let refresh (self : t) : unit = self.cache <- []

(* Tear the chain down: every plugin instance is deactivated and unloaded,
   in reverse, releasing whatever a provider acquired at activation.
   Afterwards `stores` and `sources` are empty, `get` raises and `tryget`
   misses - and redaction still knows every value ever resolved, which is
   the whole point of keeping `seen` separately. *)
let close (self : t) : unit =
  Host.close self.thost;
  self.entries <- [];
  self.cache <- []

(* ---- print hooks -----------------------------------------------------

   `cache` and `seen` are ordinary fields, so the default printer of a
   `t` would put every resolved secret on the page. Neither hook below can
   reach a value. *)

let to_string (self : t) : string = "Sekreto { stores: [ " ^ String.concat ", " (stores self) ^ " ] }"
let to_json (self : t) : string =
  (* Built as a Json value and written by the port's own writer, NOT
     concatenated. Canonical returns an OBJECT here
     (typescript/src/Sekreto.ts toJSON) and lets JSON.stringify escape it,
     so a store name carrying a quote, a backslash or a control character
     is valid JSON in every port. Assembling the text by hand produced
     invalid JSON for exactly those names, and no spec entry covers this
     hook -- an audit caught it, not the corpus. *)
  Json.stringify (Json.obj [ ("stores", Json.arr (List.map Json.str (stores self))) ])
