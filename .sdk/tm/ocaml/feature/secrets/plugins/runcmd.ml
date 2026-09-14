(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/runcmd.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Running a store's own CLI, and collecting both its streams.

   Two of the ten plugin kinds read their store through a child process -
   `boru` and `secretspec` - and a child process is one of the three things
   that keeps a kind out of the core, beside a socket and a signature. *)

open Secret

type ran = { out : string; why : string; status : int }

(* Where a command lives, or nowhere.

   Resolved before forking: OCaml's `create_process` execs in the child, so
   a command that is not there makes the child exit 127 with no error in the
   parent - which is indistinguishable from a command that ran and failed.
   "cannot run" and "the store said no" are different answers. *)
let findexe (command : string) : string option =
  let executable path = match Unix.access path [ Unix.X_OK ] with () -> true | exception _ -> false in

  if String.contains command '/' then if executable command then Some command else None
  else
    let path = match Sys.getenv_opt "PATH" with Some value -> value | None -> "/usr/bin:/bin" in
    let rec walk = function
      | [] -> None
      | dir :: rest ->
        let cand = (if "" = dir then "." else dir) ^ "/" ^ command in
        if executable cand then Some cand else walk rest
    in
    walk (String.split_on_char ':' path)

(* Run a child to completion and collect both its streams.

   The two streams are drained CONCURRENTLY, through one select loop.
   Reading stdout to EOF and only then reading stderr deadlocks the moment
   the child writes more than one pipe buffer (64 KiB on Linux) to stderr:
   the parent is blocked waiting for stdout, the child is blocked waiting
   for room on stderr, and neither can move. Nothing here sets a timeout, so
   that hang is permanent - `get` simply never returns. secretspec's
   diagnostics are box-drawn and reach that size easily.

   The child's stdin is closed rather than left open on a pipe nobody writes
   to, so a CLI that reads it - one prompting for a passphrase when its
   environment variable is absent - sees EOF and gives up instead of waiting
   forever.

   Arguments go as an array, never through a shell, and no secret is ever
   put on a command line where the process table would publish it. *)
let runcmd (argv : string list) (env : string array) (command : string) : ran =
  let exe =
    match findexe command with
    | Some path -> path
    | None -> fail ("sekreto: cannot run " ^ command ^ ": No such file or directory")
  in

  let outr, outw = Unix.pipe () in
  let errr, errw = Unix.pipe () in
  let inr, inw = Unix.pipe () in
  Unix.close inw;

  let pid =
    match Unix.create_process_env exe (Array.of_list argv) env inr outw errw with
    | pid -> pid
    | exception Unix.Unix_error (err, _, _) ->
      List.iter (fun fd -> try Unix.close fd with _ -> ()) [ inr; outr; outw; errr; errw ];
      fail ("sekreto: cannot run " ^ command ^ ": " ^ Unix.error_message err)
  in

  Unix.close inr;
  Unix.close outw;
  Unix.close errw;

  let obuf = Buffer.create 4096 and ebuf = Buffer.create 4096 in
  let live = ref [ outr; errr ] in
  let chunk = Bytes.create 65536 in

  while [] <> !live do
    let ready, _, _ = Unix.select !live [] [] (-1.0) in
    List.iter
      (fun fd ->
        let got = try Unix.read fd chunk 0 65536 with Unix.Unix_error _ -> 0 in
        if 0 = got then begin
          (try Unix.close fd with _ -> ());
          live := List.filter (fun other -> other <> fd) !live
        end
        else Buffer.add_subbytes (if fd = outr then obuf else ebuf) chunk 0 got)
      ready
  done;

  let status = match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code | Unix.WSTOPPED code -> 128 + code
  in

  { out = Buffer.contents obuf; why = trim (Buffer.contents ebuf); status }
