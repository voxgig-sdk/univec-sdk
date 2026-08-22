(* JSON text -> voxgig struct value.
 *
 * A dependency-free reader, so the SDK can parse JSON with no opam packages -
 * the same position every other target is in (elixir's Univec.Json,
 * clojure's sdk.core/json-parse, the json_parse in c/rust/zig).
 *
 * It lives in the RUNTIME rather than the test tree because the generated
 * config uses it: above a size threshold the API model is emitted as a JSON
 * string constant and parsed here (sdkgen rung L1) instead of as a literal the
 * compiler has to walk. `test/struct_corpus.ml` uses this same function rather
 * than its own copy, so the corpus and the SDK cannot disagree about what a
 * given JSON text means.
 *
 * Numbers are read as Num (float), which is exactly what formatOcamlValue
 * emits for the literal form - so the two representations cannot disagree
 * about the type of a whole number.
 *)

open Voxgig_struct

(* ---------------- JSON reader -> value ---------------- *)

let json_read (s : string) : value =
  let n = String.length s in
  let pos = ref 0 in
  let peek () = if !pos < n then Some s.[!pos] else None in
  let adv () = incr pos in
  let skip_ws () =
    while !pos < n && (match s.[!pos] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false) do incr pos done
  in
  let rec pval () =
    skip_ws ();
    match peek () with
    | Some '{' -> pobj ()
    | Some '[' -> parr ()
    | Some '"' -> Str (pstr ())
    | Some 't' -> pos := !pos + 4; Bool true
    | Some 'f' -> pos := !pos + 5; Bool false
    | Some 'n' -> pos := !pos + 4; Null
    | _ -> pnum ()
  and pobj () =
    adv (); skip_ws ();
    if peek () = Some '}' then (adv (); empty_map ())
    else begin
      let m = empty_map () in
      let rec loop () =
        skip_ws ();
        let k = pstr () in
        skip_ws (); adv (); (* : *)
        let v = pval () in
        ignore (setprop m (Str k) v);
        skip_ws ();
        let c = (match peek () with Some c -> adv (); c | None -> '}') in
        if c = ',' then loop () else m
      in loop ()
    end
  and parr () =
    adv (); skip_ws ();
    if peek () = Some ']' then (adv (); empty_list ())
    else begin
      let acc = ref [] in
      let rec loop () =
        let v = pval () in
        acc := v :: !acc;
        skip_ws ();
        let c = (match peek () with Some c -> adv (); c | None -> ']') in
        if c = ',' then loop () else lst (List.rev !acc)
      in loop ()
    end
  and pstr () =
    adv ();
    let b = Buffer.create 16 in
    let rec loop () =
      let c = s.[!pos] in adv ();
      if c = '"' then Buffer.contents b
      else if c = '\\' then begin
        let e = s.[!pos] in adv ();
        (match e with
         | '"' -> Buffer.add_char b '"' | '\\' -> Buffer.add_char b '\\'
         | '/' -> Buffer.add_char b '/' | 'n' -> Buffer.add_char b '\n'
         | 't' -> Buffer.add_char b '\t' | 'r' -> Buffer.add_char b '\r'
         | 'b' -> Buffer.add_char b '\b' | 'f' -> Buffer.add_char b '\012'
         | 'u' ->
           let hex = String.sub s !pos 4 in pos := !pos + 4;
           let code = int_of_string ("0x" ^ hex) in
           if code < 128 then Buffer.add_char b (Char.chr code)
           else if code < 2048 then begin
             Buffer.add_char b (Char.chr (0xC0 lor (code lsr 6)));
             Buffer.add_char b (Char.chr (0x80 lor (code land 0x3F)))
           end else begin
             Buffer.add_char b (Char.chr (0xE0 lor (code lsr 12)));
             Buffer.add_char b (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
             Buffer.add_char b (Char.chr (0x80 lor (code land 0x3F)))
           end
         | c -> Buffer.add_char b c);
        loop ()
      end else (Buffer.add_char b c; loop ())
    in loop ()
  and pnum () =
    let start = !pos in
    while !pos < n && (match s.[!pos] with
        | '0'..'9' | '-' | '+' | '.' | 'e' | 'E' -> true | _ -> false) do incr pos done;
    let tok = String.sub s start (!pos - start) in
    Num (float_of_string tok)
  in
  pval ()
