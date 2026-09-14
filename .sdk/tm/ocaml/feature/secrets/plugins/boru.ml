(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/boru.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `boru` provider kind, as a voxgig/plugin definition.

   Two ways in, and both keep it out of the core: boru's own CLI, which is
   a child process, and boru's wire protocol, which is a socket.

   A port of typescript/plugins/boru.ts, which is canonical. *)

open Secret
open Provider
open Httpjson
open Runcmd

(* Does this boru failure mean "no such secret" rather than "I could not
   answer"? Matched on boru's own wording for a missing alias: a locked
   vault or a wrong passphrase is not a miss, and treating it as one would
   fall through to a weaker store without saying so. *)
let borumiss (why : string) : bool = None <> findsub why "no alias named"

(* A boru vault (https://github.com/boru-lang/boru).

   Two ways in, both boru's own.

   With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
   secret on stdout and nothing else. The passphrase is read by boru itself
   from BORU_VAULT_PASSPHRASE; sekreto never accepts it as config and never
   puts it on a command line, where it would show up in the process table.

   With an `addr`, boru's wire protocol: a read-only, HashiCorp-shaped
   provision API authenticated by a capability token. A sekreto name is
   already a valid boru alias, and boru aliases KEEP THEIR DOTS, so
   `api.token` is the single path segment `api.token` - not the `api`/`token`
   split a HashiCorp KV gets. The value is the `value` field. *)
let boru_provider (commandgiven : string) (namespace : string) (home : string)
    (addrgiven : string) (token : string) (mountgiven : string) : provider =
  let command = if "" = commandgiven then "boru" else commandgiven in
  let addr = trimslash addrgiven in
  let mount = if "" = mountgiven then "secret" else mountgiven in

  let wirelookup name =
    checkaddr addr;

    let alias = if "" = namespace then name else namespace ^ "/" ^ name in
    let url = addr ^ "/v1/" ^ mount ^ "/data/" ^ alias in

    let res = fetchjson ~headers:[ ("X-Vault-Token", token) ] "GET" url in

    if 404 = res.status then None
    else if 200 <> res.status then
      fail ("sekreto: boru serve error: " ^ string_of_int res.status ^ ": " ^ url)
    else digtext res.jbody [ "data"; "data"; "value" ]
  in

  {
    lookup =
      (fun name ->
        ignore (checkname name);

        if "" <> addr then wirelookup name
        else begin
          let alias = if "" = namespace then name else namespace ^ ":" ^ name in
          let env =
            if "" = home then Unix.environment ()
            else
              Array.append
                (Array.of_list
                   (List.filter
                      (fun entry -> not (String.starts_with ~prefix:"BORU_HOME=" entry))
                      (Array.to_list (Unix.environment ()))))
                [| "BORU_HOME=" ^ home |]
          in

          let ran = runcmd [ command; "vault"; "get"; "--reveal"; alias ] env command in

          if 0 = ran.status then
            (* boru prints the value and one newline, and nothing else. *)
            Some (dropsuffix ran.out "\n")
          else if borumiss ran.why then None
          else
            fail
              ("sekreto: boru vault error: "
              ^ if "" = ran.why then "exit " ^ string_of_int ran.status else ran.why)
        end);
    describe =
      (fun () ->
        if "" <> addr then "boru:" ^ addr
        else if "" = namespace then "boru"
        else "boru:" ^ namespace);
  }

let plugin () : Defs.definition =
  providerplugin "boru" (fun spec ->
      boru_provider spec.command spec.namespace spec.home spec.addr spec.token spec.mount)
