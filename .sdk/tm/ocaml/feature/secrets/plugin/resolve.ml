(* VENDORED: @voxgig/plugin sdk-20260908-1556-0 (ocaml/src/resolve.ml) *)
(* Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0] *)
(* License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream. *)
(* Dynamic resolution (§10.2) — name to candidate module ids.

   PURE. It returns the ids a host WOULD try, in order; it does not
   load anything. That separation is what lets the corpus pin
   resolution in every language including those with no dynamic loading
   at all — ocaml among them — and it is why §15.4 puts real module
   loading in per-port integration tests rather than here. *)

module V = Value

let pushuniq out id =
  if not (List.exists (fun v -> V.as_str v = id) (V.items out)) then
    V.push out (V.vstr id)

let default_prefix = [ "@voxgig/plugin-"; "voxgig-plugin-"; "plugin-"; "" ]

let resolvecandidates name sources =
  let out = V.vlist () in
  let n = if V.is_str name then V.as_str name else "" in
  (* A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). `@acme/thing` is
     already a package id; prefixing it produces
     `@voxgig/plugin-@acme/thing`, which is not a thing that can
     exist. *)
  if 0 < String.length n && '@' = n.[0] then (V.push out (V.vstr n); out)
  else if not (V.is_list sources && 0 < V.len sources) then begin
    List.iter (fun p -> pushuniq out (p ^ n)) default_prefix;
    out
  end
  else begin
    List.iter
      (fun src ->
        let kind = V.as_str (V.get src "kind") in
        if "module" = kind then begin
          let prefix = V.get src "prefix" in
          if V.is_list prefix && 0 < V.len prefix then
            List.iter (fun p -> pushuniq out (V.as_str p ^ n)) (V.items prefix)
          else pushuniq out n
        end
        else if "path" = kind then begin
          let dir = V.as_str (V.get src "dir") in
          (* Trailing slashes are trimmed, so `lib/` and `lib` give one
             id rather than two spellings of it. *)
          let e = ref (String.length dir) in
          while 0 < !e && '/' = dir.[!e - 1] do decr e done;
          pushuniq out (String.sub dir 0 !e ^ "/" ^ n)
        end)
      (V.items sources);
    out
  end

(* A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name
   with a letter or `@`, so `./local/thing` is not a ref and never
   reaches candidate generation — seneca allows a path where a plugin
   name goes, and this design deliberately does not, because a ref is
   an ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.

   Loading from an explicit location bypasses candidate generation
   entirely: `from` is passed to the resolver verbatim. *)
let resolvefrom from = V.oflist [ (if V.is_null from then V.vnull else from) ]
