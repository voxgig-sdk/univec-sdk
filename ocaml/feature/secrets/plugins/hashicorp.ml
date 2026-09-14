(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/hashicorp.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `hashicorp` provider kind, as a voxgig/plugin definition.

   HashiCorp Vault over HTTPS, so it is a plugin rather than a built-in
   kind: only a program that names this module links the framing, the TLS
   binding and the OpenSSL beneath it.

   A port of typescript/plugins/hashicorp.ts, which is canonical. *)

open Secret
open Provider
open Httpjson

(* HashiCorp Vault.

   KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
   takes the `token` field of `data.data`. KV v1 reads
   `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
   here" - a miss - so a vault can sit in a chain with fallbacks.

   A Vault Enterprise namespace rides the X-Vault-Namespace header, on
   logins as well as reads.

   Instead of being handed a token, the provider can log in: Kubernetes auth
   (the pod's service-account JWT, from its conventional path) or AppRole. A
   failed login is an error, never a miss - it means this store could not
   answer at all. *)
let hashicorp_provider (addr : string) (token : string) (mountgiven : string) (kv : int)
    (vaultnamespace : string) (auth : authspec option) : provider =
  let mount = if "" = mountgiven then "secret" else mountgiven in

  (* A version typo like kv: 3 must not quietly behave as v2 and turn its
     404s into misses; there is nothing safe to assume it meant. *)
  if 1 <> kv && 2 <> kv then
    fail ("sekreto: hashicorp: unsupported kv version: " ^ string_of_int kv);

  (* The working token: a configured token is kept forever, a logged-in one
     is renewed shortly before its lease runs out - a long-running process
     must not keep presenting a token the vault already expired. *)
  let livetoken = ref (if "" = token then None else Some token) in
  let renewat = ref never in

  let baseheaders () =
    if "" = vaultnamespace then [] else [ ("X-Vault-Namespace", vaultnamespace) ]
  in

  let login () =
    let use = match auth with
      | Some use -> use
      | None -> fail "sekreto: hashicorp: no token and no auth method"
    in

    let authmount = firstof [ use.amount; use.amethod ] in
    let url = trimslash addr ^ "/v1/auth/" ^ authmount ^ "/login" in

    let body =
      match use.amethod with
      | "kubernetes" ->
        let jwt =
          if "" <> use.jwt then use.jwt
          else begin
            let path =
              if "" = use.jwtfile then "/var/run/secrets/kubernetes.io/serviceaccount/token"
              else use.jwtfile
            in
            match readfile path with
            | text -> trim text
            | exception Unix.Unix_error _ ->
              fail ("sekreto: hashicorp: cannot read jwt file " ^ path)
          end
        in
        Json.obj [ ("role", Json.str use.role); ("jwt", Json.str jwt) ]
      | "approle" ->
        Json.obj [ ("role_id", Json.str use.roleid); ("secret_id", Json.str use.secretid) ]
      | other -> fail ("sekreto: hashicorp: unknown auth method: " ^ other)
    in

    let res = fetchjson ~headers:(baseheaders ()) ~body:(Json.stringify body) "POST" url in
    let got = digtext res.jbody [ "auth"; "client_token" ] in

    if 200 <> res.status || not (isset got) then
      fail ("sekreto: hashicorp login failed: " ^ string_of_int res.status ^ ": " ^ url);

    renewat := renewtime (Json.odig res.jbody [ "auth"; "lease_duration" ]);
    Option.get got
  in

  {
    lookup =
      (fun name ->
        checkaddr addr;

        if None = !livetoken || nowms () >= !renewat then livetoken := Some (login ());

        let ref_ = vaultref name in
        let base = trimslash addr ^ "/v1/" ^ mount in
        let url = if 1 = kv then base ^ "/" ^ ref_.path else base ^ "/data/" ^ ref_.path in

        let headers =
          baseheaders () @ [ ("X-Vault-Token", Option.value ~default:"" !livetoken) ]
        in

        let res = fetchjson ~headers "GET" url in

        if 404 = res.status then None
        else if 200 <> res.status then
          fail ("sekreto: hashicorp error: " ^ string_of_int res.status ^ ": " ^ url)
        else
          let data = if 1 = kv then Json.odig res.jbody [ "data" ] else Json.odig res.jbody [ "data"; "data" ] in
          digtext data [ ref_.field ]);
    describe = (fun () -> "hashicorp:" ^ addr ^ "/" ^ mount);
  }

(* The definition the catalog holds. A function, so two chains never share
   one and nothing is built at load time. *)
let plugin () : Defs.definition =
  providerplugin "hashicorp" (fun spec ->
      hashicorp_provider spec.addr spec.token spec.mount spec.kv spec.vaultnamespace spec.auth)
