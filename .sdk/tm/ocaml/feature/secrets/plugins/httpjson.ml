(* VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (ocaml/plugins/httpjson.ml) *)
(* Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* One JSON round-trip, and the reads a response body needs.

   THE SHARED HTTP-JSON HELPER, AND IT LIVES UNDER plugins/ BECAUSE OF
   THAT. Seven of the ten plugin kinds dial a store over HTTPS; the four
   built-in kinds dial nothing, so a chain of built-ins must never link
   this module, the framing under it or the TLS binding under that. *)

open Secret

(* A url without its query string, for a message that must not leak one. *)
let bare = Http.bare

(* One JSON round-trip's result: the status, and the parsed body. *)
type answer = { status : int; jbody : Json.t option }

(* One JSON round-trip. Network failure is always an error - an unreachable
   store is a store that could not answer, never a store without the
   secret. *)
let fetchjson ?(headers = []) ?body (meth : string) (url : string) : answer =
  let res = Http.request meth url headers body in
  let parsed = Json.parse res.Http.body in

  (* A success status promised JSON; a body that does not parse means the
     store could not answer coherently, and treating it as a miss would fall
     through to a weaker store. Error statuses may carry any body - they are
     decided on status alone. *)
  if 200 = res.Http.status && None = parsed then
    fail ("sekreto: malformed response from " ^ bare url);

  { status = res.Http.status; jbody = parsed }

(* When a logged-in token must be renewed, from its expiry in seconds (a
   JSON number, or a string as Azure IMDS sends it): now + max(seconds - 60,
   1). A missing or zero expiry means never renew. *)
let never = infinity

let renewtime (expires : Json.t option) : float =
  let seconds =
    match expires with
    | Some (Json.Num value) -> value
    | Some (Json.Str value) -> ( match float_of_string_opt value with Some v -> v | None -> 0.0)
    | _ -> 0.0
  in
  if Float.is_nan seconds || 0.0 >= seconds then never
  else (Unix.gettimeofday () *. 1000.0) +. (Float.max (seconds -. 60.0) 1.0 *. 1000.0)

let nowms () : float = Unix.gettimeofday () *. 1000.0

(* ---- reading a response ---------------------------------------------- *)

(* The text at a path in a response body, or nothing. A JSON null is nothing
   - a null field is a miss, never the string `null`. *)
let digtext (body : Json.t option) (keys : string list) : string option =
  Json.otext (Json.odig body keys)

(* The string at a path, insisting it really is a string: `__type` must be
   one, a 1Password vault list must be an array, a Doppler config an
   object. *)
let digstr (body : Json.t option) (keys : string list) : string option =
  Json.oasstr (Json.odig body keys)

let isset (value : string option) : bool =
  match value with Some text -> "" <> text | None -> false
