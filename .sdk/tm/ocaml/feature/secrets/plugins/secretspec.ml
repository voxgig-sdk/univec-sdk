(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/secretspec.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* The `secretspec` provider kind, as a voxgig/plugin definition.

   SecretSpec read through its own CLI - a child process, which is one of
   the three things that keeps a kind out of the core.

   A port of typescript/plugins/secretspec.ts, which is canonical. *)

open Secret
open Provider
open Runcmd

(* Does this SecretSpec failure mean "no such secret" rather than "I could
   not answer"?

   MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec says
   `Secret 'API_TOKEN' not found` for both a name it does not declare and
   one declared with no value, and both are misses. It also says
   `Provider backend 'keyring' not found`, which is a store that could not
   answer at all - and reading that as a miss is the worst failure this
   library has. The key is required to appear, so the two cannot be
   confused. *)
let secretspecmiss (why : string) (key : string) : bool =
  None <> findsub why ("Secret '" ^ key ^ "' not found")

(* SecretSpec (https://secretspec.dev), read through its CLI.

   `backend` selects one of SecretSpec's own backends (`--provider`) and is
   called `backend` here only because `provider` already means something
   else in this library.

   A reason is required, not optional: SecretSpec records every read in an
   audit log and refuses to read at all without one. *)
let secretspec_provider (commandgiven : string) (file : string) (profile : string)
    (backend : string) (reason : string) (prefix : string) : provider =
  let command = if "" = commandgiven then "secretspec" else commandgiven in

  {
    lookup =
      (fun name ->
        let key = envkey ~prefix name in

        (* `--file` before the subcommand, `--reason` always sent. *)
        let argv =
          [ command ]
          @ (if "" = file then [] else [ "--file"; file ])
          @ [ "get"; key ]
          @ (if "" = backend then [] else [ "--provider"; backend ])
          @ (if "" = profile then [] else [ "--profile"; profile ])
          @ [ "--reason"; firstof [ reason; "sekreto" ] ]
        in

        let ran = runcmd argv (Unix.environment ()) command in

        if 0 = ran.status then Some (dropsuffix ran.out "\n")
        else if secretspecmiss ran.why key then None
        else
          fail
            ("sekreto: secretspec error: "
            ^ if "" = ran.why then "exit " ^ string_of_int ran.status else ran.why));
    describe = (fun () -> if "" = backend then "secretspec" else "secretspec:" ^ backend);
  }

let plugin () : Defs.definition =
  providerplugin "secretspec" (fun spec ->
      secretspec_provider spec.command spec.file spec.profile spec.backend spec.reason spec.prefix)
