(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/src/provider.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* What a provider's declarative form looks like, how a provider kind
   becomes a voxgig/plugin definition - and the four BUILT-IN kinds.

   THIS MODULE OPENS NO SOCKET, SIGNS NOTHING AND SPAWNS NOTHING. What
   makes a kind built in is that it needs nothing of the platform beyond
   reading a local file, so `env`, `memory`, `dotenv` and `file` are here
   and every kind that dials a store is a plugin under `plugins/`, reached
   only by a program that names it.

   Two failure shapes, and they are never interchangeable. A store that
   does not hold the secret is a MISS (None) - the chain carries on. A
   store that could not answer - bad credentials, unreachable host, missing
   configuration - is an ERROR: falling through there would quietly reach
   for a weaker store, which is the worst failure this library has.

   A port of typescript/src/provider/support.ts and
   typescript/src/provider/builtin.ts, which are canonical. *)

module V = Value
open Secret

(* ---- the declarative form -------------------------------------------- *)

(* Logging in to a vault instead of being handed a token. `amethod` is
   `kubernetes` or `approle`; `amount` defaults to the method name. *)
type authspec = {
  amethod : string;
  amount : string;
  (* kubernetes: the Vault role to log in as. *)
  role : string;
  (* kubernetes: the service-account JWT itself (tests). *)
  jwt : string;
  (* kubernetes: where the JWT lives; the conventional pod path by default. *)
  jwtfile : string;
  (* approle: the role and secret ids. *)
  roleid : string;
  secretid : string;
}

let noauth =
  { amethod = ""; amount = ""; role = ""; jwt = ""; jwtfile = ""; roleid = ""; secretid = "" }

(* What a credential field reports about itself. *)
let setornot (value : string) : string = if "" = value then "[unset]" else "[set]"

(* Printed without its credentials.

   A derived printer would put the service-account JWT and the AppRole
   secret id into `Printf.eprintf "bad chain: %s"`, which is what someone
   writes when a chain will not build. *)
let authtostring (auth : authspec) : string =
  Printf.sprintf "AuthSpec(method=%s, mount=%s, role=%s, jwtfile=%s, roleid=%s, jwt=%s, secretid=%s)"
    auth.amethod auth.amount auth.role auth.jwtfile auth.roleid (setornot auth.jwt)
    (setornot auth.secretid)

(* The declarative form of a provider, as used in config and in the shared
   spec. `kind` picks the provider; everything else is that kind's own.

   String fields carry an empty-string default rather than an option:
   "not configured" and "configured empty" mean the same thing everywhere in
   this library. `kv` is the only number and `values` the only map - and it
   is an ordered association list, not a hash table, because the spec
   compares whole maps. *)
type spec = {
  kind : string;
  (* The store name `getfrom` addresses. Defaults to `kind`. *)
  name : string;
  prefix : string;
  (* dotenv: the file to read. secretspec: the declaration to read. *)
  file : string;
  (* memory: literal values, keyed like environment variables. *)
  values : (string * string) list;
  (* file: the directory of one-secret-per-file entries. *)
  dir : string;
  (* hashicorp / boru (wire) / gcp / 1password / doppler / infisical: the base URL. *)
  addr : string;
  token : string;
  (* hashicorp / boru (wire): the KV mount (default `secret`). *)
  mount : string;
  (* hashicorp: KV engine version, 1 or 2 (default 2). *)
  kv : int;
  (* hashicorp: Vault Enterprise namespace (X-Vault-Namespace). *)
  vaultnamespace : string;
  (* hashicorp: log in for a token instead of being handed one. *)
  auth : authspec option;
  (* boru / secretspec: the executable to run. *)
  command : string;
  (* secretspec: the profile to read. *)
  profile : string;
  (* secretspec: which of ITS backends to read from, named `backend` here
     because `provider` already means a sekreto provider. *)
  backend : string;
  (* secretspec: the audit reason recorded for the read. *)
  reason : string;
  (* boru: the namespace qualifying the alias, and the vault home. *)
  namespace : string;
  home : string;
  (* aws: region and credentials; the standard AWS_* variables fill the rest. *)
  region : string;
  keyid : string;
  secret : string;
  session : string;
  (* gcp / doppler / infisical: the project, however that store names it. *)
  project : string;
  (* azure: the Key Vault name or full URL. 1password: the vault name or id. *)
  vault : string;
  (* azure: client-credential login. infisical: universal-auth login. *)
  tenant : string;
  clientid : string;
  clientsecret : string;
  (* azure: where to log in / where IMDS answers. gcp: the metadata server. *)
  loginaddr : string;
  imdsaddr : string;
  metadataaddr : string;
  (* azure: the Key Vault API version (default 7.4). *)
  apiversion : string;
  (* doppler: the config slug (with `project`). *)
  config : string;
  (* infisical: the environment slug and secret path. *)
  environment : string;
  secretpath : string;
}

let nospec =
  {
    kind = "";
    name = "";
    prefix = "";
    file = "";
    values = [];
    dir = "";
    addr = "";
    token = "";
    mount = "";
    kv = 2;
    vaultnamespace = "";
    auth = None;
    command = "";
    profile = "";
    backend = "";
    reason = "";
    namespace = "";
    home = "";
    region = "";
    keyid = "";
    secret = "";
    session = "";
    project = "";
    vault = "";
    tenant = "";
    clientid = "";
    clientsecret = "";
    loginaddr = "";
    imdsaddr = "";
    metadataaddr = "";
    apiversion = "";
    config = "";
    environment = "";
    secretpath = "";
  }

(* Printed without its credentials. See authtostring: the obvious printer
   would put the Vault token, the AWS secret access key and the Azure client
   secret into whatever formatted it. *)
let spectostring (spec : spec) : string =
  Printf.sprintf "ProviderSpec(kind=%s, name=%s, addr=%s, token=%s, secret=%s, clientsecret=%s, auth=%s)"
    spec.kind spec.name spec.addr (setornot spec.token) (setornot spec.secret)
    (setornot spec.clientsecret)
    (match spec.auth with None -> "none" | Some auth -> authtostring auth)

(* ---- shared machinery ------------------------------------------------ *)

let getenv (name : string) : string =
  match Sys.getenv_opt name with Some value -> value | None -> ""

(* The first candidate that is set and non-empty, or empty. *)
let firstof (candidates : string list) : string =
  match List.find_opt (fun value -> "" <> value) candidates with Some value -> value | None -> ""

let trimslash (text : string) : string = dropsuffix text "/"

(* An address with any userinfo replaced by `[redacted]`, for messages.

   Every refusal below names the address it refused, and one of them fires
   precisely because the address carries a credential - so printing it
   verbatim would write the password to stderr and into the logs. It cannot
   be cleaned up afterwards either: that password was never resolved as a
   secret, so `redact` has never seen it and never will. *)
let safeaddr (addr : string) : string =
  match findsub addr "://" with
  | None -> addr
  | Some mark ->
    let rest = String.sub addr (mark + 3) (String.length addr - mark - 3) in
    let stop = match splitfirst rest "/?#" with Some at -> at | None -> String.length rest in
    let authority = String.sub rest 0 stop in
    (match String.rindex_opt authority '@' with
    | None -> addr
    | Some at ->
      String.sub addr 0 (mark + 3)
      ^ "[redacted]"
      ^ String.sub addr (mark + 3 + at) (String.length addr - mark - 3 - at))

(* Refuse to send a secret-bearing credential in the clear.

   A vault API is HTTPS in any real deployment; plaintext is a dev-mode
   convenience. Sending a token over http to anything but the local machine
   puts both the token and the secret it fetches on the wire for anyone on
   the path, so sekreto will not do it. Loopback stays allowed: that is
   `vault server -dev`, `boru vault serve`, and this repo's own harness.

   The address is read by hand, in the same handful of steps in every port,
   rather than by each platform's URL parser. A dozen parsers disagree about
   malformed input - where userinfo ends, whether `0177.0.0.1` is loopback,
   what an unclosed bracket means - and a check that answers differently in
   different ports is not a check.

   The rule this parse obeys: it is never MORE PERMISSIVE than the client
   that will dial the address. It ends the authority at `/`, `?` or `#`
   only, so a client that also breaks on a backslash can only ever see a
   shorter host than this does. It refuses userinfo outright rather than
   locating its end. It compares the host literally, so a numeric form no
   parser here agrees on is refused rather than guessed at. *)
let checkaddr (addr : string) : unit =
  let scheme =
    if String.starts_with ~prefix:"https://" addr then "https://"
    else if String.starts_with ~prefix:"http://" addr then "http://"
    else fail ("sekreto: not an http(s) address: " ^ safeaddr addr)
  in

  let rest = String.sub addr (String.length scheme) (String.length addr - String.length scheme) in
  let stop = match splitfirst rest "/?#" with Some at -> at | None -> String.length rest in
  let authority = String.sub rest 0 stop in

  (* Userinfo is refused outright rather than parsed around, and on https as
     well as http. No store this library speaks authenticates by userinfo -
     they take a token or a signature - so an address carrying one is a
     mistake at best. At worst it is the attack this whole function exists
     to stop: `http://localhost:8200@evil.example.com/` is a request to
     evil.example.com that reads, to anything splitting the authority on a
     colon, as loopback. *)
  if String.contains authority '@' then
    fail ("sekreto: refusing an address with embedded credentials: " ^ safeaddr addr);

  (* An opening bracket with no closing one is not an address at all. *)
  if String.length authority > 0 && '[' = authority.[0] && not (String.contains authority ']') then
    fail ("sekreto: not a valid http(s) address: " ^ safeaddr addr);

  if "https://" <> scheme then begin
    (* A bracketed IPv6 literal keeps its brackets. Splitting the authority
       on the first colon yields `[`, which could never match the allowlist
       and refused a legitimate local vault. *)
    let host =
      String.lowercase_ascii
        (if String.length authority > 0 && '[' = authority.[0] then
           String.sub authority 0 (String.index authority ']' + 1)
         else
           match String.index_opt authority ':' with
           | Some at -> String.sub authority 0 at
           | None -> authority)
    in

    (* Literal, and exactly four entries. Nothing is normalised, so
       `0177.0.0.1`, `2130706433`, `127.0.0.2` and `[::ffff:127.0.0.1]` are
       all refused rather than guessed at. *)
    if "localhost" <> host && "127.0.0.1" <> host && "::1" <> host && "[::1]" <> host then
      fail ("sekreto: refusing to send a token in plaintext to " ^ safeaddr addr ^ " (use https)")
  end

(* Read a whole file, letting the platform's own error code through so that
   the caller can tell "no secrets here" from "I could not answer". *)
let readfile (path : string) : string =
  let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with _ -> ())
    (fun () ->
      let out = Buffer.create 4096 in
      let chunk = Bytes.create 65536 in
      let rec loop () =
        let got = Unix.read fd chunk 0 65536 in
        if 0 < got then begin
          Buffer.add_subbytes out chunk 0 got;
          loop ()
        end
      in
      loop ();
      Buffer.contents out)

(* Does this read failure mean "no secrets here" rather than "I could not
   answer"?

   Absence is a MISS and the chain carries on; anything else - permission
   denied, an unreadable mount, a failing disk - is an ERROR, because
   returning a miss there falls silently through to a weaker store. Keyed on
   the platform's not-found codes rather than on an `exists` predicate,
   which answers false for a permission error and would turn a locked mount
   into a miss. *)
let notfound (err : Unix.error) : bool = Unix.ENOENT = err || Unix.ENOTDIR = err

(* Join a directory and a file name. `Filename.concat` would turn an empty
   directory into a leading slash and read from the root. *)
let joinpath (dir : string) (name : string) : string =
  if "" = dir then name else Filename.concat dir name

(* ---- the four built-in kinds ------------------------------------------

   The criterion for "built in": needs nothing of the platform beyond
   reading a local file - no socket, no TLS, no crypto, no child process. *)

(* Environment variables: `api.token` from `API_TOKEN`. *)
let env_provider ?(source : (string * string) list option) (prefix : string) : provider =
  {
    lookup =
      (fun name ->
        let key = envkey ~prefix name in
        match source with None -> Sys.getenv_opt key | Some values -> List.assoc_opt key values);
    describe = (fun () -> if "" = prefix then "env" else "env:" ^ prefix);
  }

(* Literal values, keyed like environment variables. The spec uses this to
   test chain behaviour without touching the outside world. *)
let memory_provider (values : (string * string) list) (prefix : string) : provider =
  {
    lookup = (fun name -> List.assoc_opt (envkey ~prefix name) values);
    describe = (fun () -> if "" = prefix then "memory" else "memory:" ^ prefix);
  }

(* A `.env` file, read ONCE, LAZILY, keyed exactly like the environment.

   Lazy is required, not a nicety: the `stores` corpus group puts a dotenv
   provider in a chain and never looks anything up, so an eager constructor
   would read whatever `.env` happens to sit in the working directory. *)
let dotenv_provider (file : string) (prefix : string) : provider =
  let values = ref None in

  let load () =
    match !values with
    | Some loaded -> loaded
    | None ->
      let loaded =
        match parsedotenv (readfile file) with
        | parsed -> parsed
        (* An absent file - or an absent directory - means "no secrets
           here", exactly like the file provider. *)
        | exception Unix.Unix_error (err, _, _) when notfound err -> []
        | exception Unix.Unix_error (err, _, _) ->
          fail ("sekreto: dotenv provider cannot read " ^ file ^ ": " ^ Unix.error_message err)
      in
      values := Some loaded;
      loaded
  in

  {
    lookup = (fun name -> List.assoc_opt (envkey ~prefix name) (load ()));
    describe = (fun () -> "dotenv:" ^ file);
  }

(* A directory of one-secret-per-file entries, keyed like the environment:
   `api.token` reads `<dir>/API_TOKEN`.

   This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
   secret, and a systemd credentials directory, so those all work with no
   further configuration. Read on every lookup, never cached - a mounted
   secret is rotated underneath a running process. One trailing newline is
   stripped: tools that write these files disagree about it, and a newline
   is never part of a secret on purpose. *)
let file_provider (dir : string) (prefix : string) : provider =
  {
    lookup =
      (fun name ->
        let path = joinpath dir (envkey ~prefix name) in
        match readfile path with
        | body ->
          let body =
            if String.ends_with ~suffix:"\r\n" body then String.sub body 0 (String.length body - 2)
            else if String.ends_with ~suffix:"\n" body then String.sub body 0 (String.length body - 1)
            else body
          in
          Some body
        | exception Unix.Unix_error (err, _, _) when notfound err -> None
        | exception Unix.Unix_error (err, _, _) ->
          fail ("sekreto: file provider cannot read " ^ path ^ ": " ^ Unix.error_message err));
    describe = (fun () -> "file:" ^ dir);
  }

(* ---- a provider kind as a voxgig/plugin definition -------------------- *)

(* The export key under which a provider definition publishes the provider
   it built. `Sekreto` reads `<ref>/provider` off the host. *)
let provider_export = "provider"

(* The voxgig/plugin error code a Sekreto_error travels under when it is
   raised inside a definition's `define`.

   plugin wraps a code-less error raised by a callback as
   `plugin_define_failed`, and keeps an error that already carries a code. A
   provider that refuses its own configuration - `kv: 3`, a missing project
   - raises a Sekreto_error, and the spec pins that message byte for byte,
   so it must come back out of the host exactly as it went in.
   `providerplugin` gives it this code on the way in; `Sekreto` turns it
   back into a Sekreto_error on the way out. *)
let error_code = "sekreto_error"

(* WHERE THE BUILT PROVIDERS LIVE, AND WHY THEY LIVE HERE.

   A plugin value carries numbers, strings, lists and maps - never a
   closure - so `inst.exports` cannot hold the provider itself. A
   definition's `define` therefore exports the HANDLE of the provider it
   built and `Sekreto` reads it back, which is the shape the zig port takes
   for the same reason (docs/design/plugin-providers.md).

   The table is module-global, so `Sekreto.close` hands every handle back
   and a construction that fails releases the handles it took. No thread
   safety is claimed across concurrent constructions, exactly as zig's
   claims none. *)
let built : (int, provider) Hashtbl.t = Hashtbl.create 16

let lasthandle = ref 0

(* The handle is read out of the counter ONCE, before the table is touched,
   and that read is what is returned. Reading `!lasthandle` back after the
   `Hashtbl.replace` would be a second read across an allocation, and on a
   runtime that preempts there - systhreads does - a construction on another
   thread could bump the counter in between and hand this one somebody
   else's handle. No thread safety is claimed here either way; this costs
   nothing and removes the one window where the failure would be a silent
   cross-wire rather than an error. *)
let stash (made : provider) : int =
  incr lasthandle;
  let handle = !lasthandle in
  Hashtbl.replace built handle made;
  handle

let unstash (handle : int) : unit = Hashtbl.remove built handle

(* The provider a handle stands for, or nothing when the definition
   exported none - which is how a definition that is not a provider plugin
   at all is told apart from one that is. *)
let providerof (handle : int) : provider option = Hashtbl.find_opt built handle

(* How many providers the table is holding. A chain that has been closed,
   or one whose construction was refused, must leave this where it found
   it; `test/plugins.ml` reads it before and after. *)
let stashed () : int = Hashtbl.length built

(* The declarative form as a plugin options map, and back.

   The spec's own key names, so the map a config DOCUMENT would carry is
   the map an instance carries: `path` for the infisical secret path, and
   `method`/`mount` inside `auth`, exactly as the shared spec spells
   them. *)
let optionsof (spec : spec) : V.t =
  let out = V.vmap () in
  let text key value = if "" <> value then V.set out key (V.vstr value) in

  text "kind" spec.kind;
  text "name" spec.name;
  text "prefix" spec.prefix;
  text "file" spec.file;
  if [] <> spec.values then begin
    let values = V.vmap () in
    List.iter (fun (key, value) -> V.set values key (V.vstr value)) spec.values;
    V.set out "values" values
  end;
  text "dir" spec.dir;
  text "addr" spec.addr;
  text "token" spec.token;
  text "mount" spec.mount;
  V.set out "kv" (V.vnum (float_of_int spec.kv));
  text "vaultnamespace" spec.vaultnamespace;
  (match spec.auth with
  | None -> ()
  | Some auth ->
    let use = V.vmap () in
    V.set use "method" (V.vstr auth.amethod);
    V.set use "mount" (V.vstr auth.amount);
    V.set use "role" (V.vstr auth.role);
    V.set use "jwt" (V.vstr auth.jwt);
    V.set use "jwtfile" (V.vstr auth.jwtfile);
    V.set use "roleid" (V.vstr auth.roleid);
    V.set use "secretid" (V.vstr auth.secretid);
    V.set out "auth" use);
  text "command" spec.command;
  text "profile" spec.profile;
  text "backend" spec.backend;
  text "reason" spec.reason;
  text "namespace" spec.namespace;
  text "home" spec.home;
  text "region" spec.region;
  text "keyid" spec.keyid;
  text "secret" spec.secret;
  text "session" spec.session;
  text "project" spec.project;
  text "vault" spec.vault;
  text "tenant" spec.tenant;
  text "clientid" spec.clientid;
  text "clientsecret" spec.clientsecret;
  text "loginaddr" spec.loginaddr;
  text "imdsaddr" spec.imdsaddr;
  text "metadataaddr" spec.metadataaddr;
  text "apiversion" spec.apiversion;
  text "config" spec.config;
  text "environment" spec.environment;
  text "path" spec.secretpath;
  out

(* A non-string reads as the empty string, because "not configured" and
   "configured empty" mean the same thing everywhere in this library. *)
let optiontext (options : V.t) (key : string) : string = V.as_str (V.get options key)

let specof (options : V.t) : spec =
  let text = optiontext options in

  let values =
    let held = V.get options "values" in
    if V.is_map held then List.map (fun key -> (key, V.as_str (V.get held key))) (V.keys held)
    else []
  in

  let auth =
    let held = V.get options "auth" in
    if not (V.is_map held) then None
    else
      Some
        {
          amethod = V.as_str (V.get held "method");
          amount = V.as_str (V.get held "mount");
          role = V.as_str (V.get held "role");
          jwt = V.as_str (V.get held "jwt");
          jwtfile = V.as_str (V.get held "jwtfile");
          roleid = V.as_str (V.get held "roleid");
          secretid = V.as_str (V.get held "secretid");
        }
  in

  {
    kind = text "kind";
    name = text "name";
    prefix = text "prefix";
    file = text "file";
    values;
    dir = text "dir";
    addr = text "addr";
    token = text "token";
    mount = text "mount";
    (* The one number, and the one field whose default is not the zero
       value: an absent `kv` is v2, never v0. *)
    kv = (let held = V.get options "kv" in if V.is_num held then int_of_float (V.as_num held) else 2);
    vaultnamespace = text "vaultnamespace";
    auth;
    command = text "command";
    profile = text "profile";
    backend = text "backend";
    reason = text "reason";
    namespace = text "namespace";
    home = text "home";
    region = text "region";
    keyid = text "keyid";
    secret = text "secret";
    session = text "session";
    project = text "project";
    vault = text "vault";
    tenant = text "tenant";
    clientid = text "clientid";
    clientsecret = text "clientsecret";
    loginaddr = text "loginaddr";
    imdsaddr = text "imdsaddr";
    metadataaddr = text "metadataaddr";
    apiversion = text "apiversion";
    config = text "config";
    environment = text "environment";
    secretpath = text "path";
  }

(* A provider kind, as a voxgig/plugin definition.

   This is the whole bridge between the two libraries. The definition's
   name is the `kind` a spec names; its `define` reads the spec back off
   `inst.options`, builds the provider with `make`, and exports the handle.
   Nothing runs at `activate`: a provider opens nothing until its first
   lookup, so there is nothing to capture - a provider that does hold a
   resource acquires it there and lets the instance scope unwind it.

   Every built-in and every plugin is made this way, so a custom provider
   kind is one call:

     providerplugin "mystore" (fun spec -> mystore_provider spec.addr) *)
let providerplugin (kind : string) (make : spec -> provider) : Defs.definition =
  {
    Defs.dname = kind;
    shape = V.vnull;
    define =
      Some
        (fun inst ->
          let made =
            match make (specof inst.Defs.options) with
            | made -> made
            | exception Sekreto_error message ->
              (* The code is what carries the message across intact: plugin
                 keeps an error that has one and wraps a code-less one as
                 `plugin_define_failed`. *)
              let details = V.vmap () in
              V.set details "ref" (V.vstr inst.Defs.iref);
              V.set details "cause" (V.vstr message);
              Types.fail error_code message ~details
          in
          Host.exportvalue inst provider_export (V.vnum (float_of_int (stash made))));
    activate = None;
    deactivate = None;
    (* THE LIFECYCLE OWNS THE RELEASE. `unload` runs this for a loaded
       instance and for a failed one alike, so a chain that was torn down
       and a chain whose construction was refused both hand their handles
       back, and no caller has to remember to. *)
    close =
      Some
        (fun inst ->
          let held = V.get inst.Defs.exports provider_export in
          if V.is_num held then unstash (int_of_float (V.as_num held)));
    reconfigure = None;
  }

(* ---- the catalog this library ships ----------------------------------- *)

(* THE BUILT-IN PROVIDER KINDS - the same four in every port.

   A function rather than a value, so two chains never share a definition
   and nothing is built at load time. A chain that reads secrets from
   options, the environment, a plaintext `.env` and a mounted secret
   directory works with no plugin loaded at all. *)
let builtins () : Defs.definition list =
  [
    providerplugin "env" (fun spec -> env_provider spec.prefix);
    providerplugin "memory" (fun spec -> memory_provider spec.values spec.prefix);
    providerplugin "dotenv"
      (fun spec -> dotenv_provider (if "" = spec.file then ".env" else spec.file) spec.prefix);
    providerplugin "file" (fun spec -> file_provider spec.dir spec.prefix);
  ]

(* Every kind this library ships, built in or as a plugin, so that an
   unknown kind can be told from a plugin that was not passed in. *)
let builtinkinds = [ "env"; "memory"; "dotenv"; "file" ]

let pluginkinds =
  [ "hashicorp"; "boru"; "awssecrets"; "awsparams"; "gcpsecrets"; "azuresecrets"; "onepassword";
    "doppler"; "infisical"; "secretspec" ]
