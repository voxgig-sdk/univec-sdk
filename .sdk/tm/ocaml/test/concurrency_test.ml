(* Requests in flight at once on one client. Each resolves its operation
 * through the cache the client's root context shares with every request, and
 * registers and cleans secrets through the one registry the client holds.
 *
 * Threads take turns on one domain and switch when the runtime's tick lands,
 * so each test runs long enough to be switched inside a resolution or a
 * registration. *)

open Voxgig_struct
open Sdk_types
open Testutil

let rounds = 3
let width = 8
let ops = 4000
let seeded = 600
let added = 100
let masked = "a [redacted] b [redacted] c"

(* Runs body on width threads released together, and returns what they raised. *)
let at_once (body : int -> unit) : string list =
  let lock = Mutex.create () in
  let ready = Condition.create () in
  let waiting = ref 0 in
  let raised = ref [] in
  let run n =
    Mutex.lock lock;
    incr waiting;
    if !waiting = width then Condition.broadcast ready
    else while !waiting < width do Condition.wait ready lock done;
    Mutex.unlock lock;
    try body n
    with e ->
      Mutex.lock lock;
      raised := fail_msg e :: !raised;
      Mutex.unlock lock
  in
  List.iter Thread.join (List.init width (Thread.create run));
  !raised

let root_of (cl : sdk_client) : ctx =
  match cl.cl_rootctx with Some c -> c | None -> failwith "no root context"

let resolve (cl : sdk_client) (k : int) : operation =
  let ctx = cl.cl_utility.u_make_context
      { (Sdk_runtime.default_ctxspec ()) with cs_opname = Some ("op" ^ string_of_int k) }
      cl.cl_rootctx in
  ctx.c_op

let () = test "concurrent resolutions share one cached operation" (fun () ->
    for round = 1 to rounds do
      let cl = Sdk_client.test () in
      let got = Array.init width (fun _ -> Array.make ops None) in
      let raised = at_once (fun n ->
          for k = 0 to ops - 1 do got.(n).(k) <- Some (resolve cl k) done) in
      check (Printf.sprintf "round %d raised: %s" round (String.concat "; " raised)) (raised = []);
      for k = 0 to ops - 1 do
        let cached = resolve cl k in
        for n = 0 to width - 1 do
          check (Printf.sprintf "round %d: op%d resolved to more than one Operation" round k)
            (match got.(n).(k) with Some op -> op == cached | None -> false)
        done
      done
    done)

let clean_str (cl : sdk_client) (text : string) : string =
  match cl.cl_utility.u_clean (root_of cl) (Str text) with Str s -> s | v -> stringify v

(* A live client whose transport answers at once. *)
let live_client () : sdk_client =
  let fetch = Func (fun _ _ _ _ ->
      Sdk_helpers.jo [
        ("status", Num 200.); ("statusText", Str "OK"); ("headers", Sdk_helpers.jo []);
        ("json", Sdk_helpers.json_thunk (Sdk_helpers.jo [("ok", Bool true)]))]) in
  Sdk_client.make (Sdk_helpers.jo [
      ("base", Str "http://concurrency.test/api");
      ("allow", Sdk_helpers.jo [("op", Str "direct")]);
      ("system", Sdk_helpers.jo [("fetch", fetch)])])

(* Registers thread n's secrets, then counts the thread out of registering. *)
let register_secrets (cl : sdk_client) (round : int) (n : int) (registering : int Atomic.t) : unit =
  Fun.protect ~finally:(fun () -> Atomic.decr registering) (fun () ->
      for k = 1 to added do
        cl.cl_utility.u_clean_add (root_of cl) (Printf.sprintf "ADDED-SECRET-%d-%d-%d" round n k)
      done)

let every_secret_masked (cl : sdk_client) (round : int) : unit =
  for n = 0 to width / 2 - 1 do
    for k = 1 to added do
      let secret = Printf.sprintf "ADDED-SECRET-%d-%d-%d" round n k in
      check_str (Printf.sprintf "round %d: %s was registered but not masked" round secret)
        (clean_str cl secret) "[redacted]"
    done
  done

(* Secrets registered on some threads while others clean: every clean masks
 * what was registered before it, the longer secret whole, and no
 * registration is lost. *)
let () = test "concurrent registration keeps every secret masked" (fun () ->
    for round = 1 to rounds do
      let cl = Sdk_client.test () in
      let add v = cl.cl_utility.u_clean_add (root_of cl) v in
      for k = 1 to seeded do add (Printf.sprintf "SEEDED-SECRET-%d-%d" round k) done;
      let inner = Printf.sprintf "INNER-SECRET-%d" round in
      add inner;
      add ("OUTER-" ^ inner ^ "-TAIL");
      let text = "a " ^ inner ^ " b OUTER-" ^ inner ^ "-TAIL c" in
      check_str (Printf.sprintf "round %d" round) (clean_str cl text) masked;
      let registering = Atomic.make (width / 2) in
      let raised = at_once (fun n ->
          if n < width / 2 then register_secrets cl round n registering
          else
            while 0 < Atomic.get registering do
              let got = clean_str cl text in
              if got <> masked then failwith ("cleaned to: " ^ got);
              Thread.yield ()
            done) in
      check (Printf.sprintf "round %d raised: %s" round (String.concat "; " raised)) (raised = []);
      every_secret_masked cl round
    done)

(* Requests on one client while secrets register on it: each request copies
 * the client's options, the registry among them. *)
let () = test "concurrent requests survive registration" (fun () ->
    for round = 1 to rounds do
      let cl = live_client () in
      for k = 1 to seeded do
        cl.cl_utility.u_clean_add (root_of cl) (Printf.sprintf "SEEDED-SECRET-%d-%d" round k)
      done;
      let registering = Atomic.make (width / 2) in
      let raised = at_once (fun n ->
          if n < width / 2 then register_secrets cl round n registering
          else
            while 0 < Atomic.get registering do
              let res = Sdk_client.direct cl
                  (Sdk_helpers.jo [("path", Str (Printf.sprintf "p%d" n))]) in
              if Sdk_helpers.getp res "ok" <> Bool true then
                failwith ("a request failed: " ^ stringify res);
              Thread.yield ()
            done) in
      check (Printf.sprintf "round %d raised: %s" round (String.concat "; " raised)) (raised = []);
      every_secret_masked cl round
    done)

let () =
  List.iter (fun m -> print_endline ("FAIL " ^ m)) (List.rev !failures);
  Printf.printf "concurrency_test: %d passed, %d failed\n" !npass !nfail;
  if !nfail > 0 then exit 1
