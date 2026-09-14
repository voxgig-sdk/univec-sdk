(* Univec SDK: the secrets feature.
 *
 * Secret access via a vendored @voxgig/sekreto provider chain, and the
 * access-token exchange some APIs require on top of it. The ocaml port of
 * tm/go/feature/secrets_feature.go - same contract, OCaml idiom - and the
 * first ocaml feature carried as a CONTAINER beside the single-module
 * sdk_features.ml: this file, the vendored trees under feature/secrets/
 * (sekreto/, plugin/, plugins/) and the shipped suite under
 * test/feature/secrets/ are what `target add` trims for a project that never
 * selected `secrets`, and what the generated feature/secrets/feature.mk
 * compiles, in dependency order, when it did.
 *
 * The SDK's `apikey` option keeps exactly its old meaning: an explicit
 * credential given in code. This feature makes it ONE SOURCE among several
 * rather than the only one: when active, the credential is resolved through
 * a sekreto chain in which the explicit option (when set) is the FIRST
 * provider - a `memory` store named `options` - so an explicit value always
 * wins, by sekreto's own first-hit rule rather than by special-case logic.
 *
 * WHERE RESOLUTION HAPPENS. The utility record holds the transport as the
 * mutable closure field `u_fetcher`, and every wire path crosses it: entity
 * ops through make_request, and the raw `direct`/`graphql` paths through
 * raw_request, which run NO feature hooks at all. So, as in go, this feature
 * wraps that field and resolves there - the one seam every request must
 * pass - rather than in the PreSpec hook ts uses. The header was already
 * built by prepare_auth from options.apikey; the wrapper rewrites it from the
 * chain-resolved value, with the same construction and the same
 * suppression rule, on the live fetchdef (whose `headers` map IS the spec's).
 * The shared options map is never written: prepare_auth reads a CLONE of it
 * (client_options_map), so writing the resolved value there would be both a
 * race in a threaded host and invisible to the reader.
 *
 * MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
 * op proceeds, unauthenticated if nothing else supplies a credential. A
 * provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
 * vault never degrades into an unauthenticated request. f_init cannot fail
 * client construction the way ts's throwing init does, so the wrapper
 * refuses to send while construction stands failed (`initerr`) or while the
 * last resolution failed. FAIL-CLOSED at the seam, and the wrapper is
 * installed BEFORE the chain is built, so a construction that fails still
 * finds the gate in place.
 *
 * EXCHANGE: some APIs will not take a long-lived credential at all. What
 * the chain resolves is then a REFRESH token, which buys a short-lived
 * ACCESS token from a token endpoint (`exchange.path`, relative to
 * options.base); the access token is what every request carries, and when
 * a response status in `exchange.statuses` (401) says it is spent the
 * wrapper buys another and retries the same request once. Test mode buys
 * nothing and answers with a deterministic fake token.
 *
 * THE EXCHANGE TRANSPORT. This SDK's core bundles no HTTP client
 * (sdk_runtime.ml fetch_no_transport). The token purchase therefore rides
 * `options.system.fetch` - the RAW platform seam below every wrapper, so no
 * recursion and no routing through the test mock - or, when the generated
 * config activated a plugin group that needs a transport, the vendored
 * sekreto HTTP client handed in as `~transport` (Config_ocaml wires
 * `Http.request` there; OpenSSL is linked on the same condition). With
 * neither, the exchange fails with a NAMED error rather than sending an
 * unauthenticated request. DELIBERATE DIVERGENCE from go/py/ts, whose
 * platforms carry an HTTP client of their own.
 *
 * THE CHAIN'S ENTRIES. An entry of `providers` is a Map (a sekreto
 * ProviderSpec, handed to `Provider.specof`), or a Func - a live provider
 * as a callable: it is asked the secret NAME and answers a Str (a hit), a
 * Null/Noval (a miss) or raises (an error). The ocaml sekreto spec has no
 * slot for a ready-made provider, so a Func becomes a synthesized
 * `providerplugin` definition (kind `custom<n>`, store `custom`) passed in
 * `~plugins` - the same seat the other ports' live-provider entries take.
 * ANYTHING ELSE - a bare kind name, a number, a null hole - is refused at
 * the gate with sekreto's own wording, never dropped: a dropped entry
 * SHORTENS the chain instead of failing it, which is the fail-open this
 * feature exists to prevent. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Sdk_features

(* The normalised exchange configuration; None when off. *)
type xchg = {
  xpath : string;
  xmethod : string;
  xrequest : string;
  xresponse : string;
  xstatuses : int list;
  xretries : int;
}

(* The message an exception carries, whichever library raised it: sekreto's
 * own for a Sekreto_error (the wording the shipped suite pins), the plugin
 * host's diagnostic for a Plugin_error that crossed the boundary unwrapped,
 * and the printer for anything else. *)
let exn_message (e : exn) : string =
  match e with
  | Secret.Sekreto_error m -> m
  | Types.Plugin_error r -> r.Types.message
  | Sdk_error_exc er -> er.err_msg
  | Failure m -> m
  | e -> Printexc.to_string e

(* A struct value as a voxgig/plugin value: the spec map a `providers` entry
 * carries, handed to Provider.specof. Closures cannot cross (a plugin value
 * holds data only), so a Func inside a spec reads as null. *)
let rec to_plugin_value (v : value) : Value.t =
  match v with
  | Str s -> Value.vstr s
  | Num n -> Value.vnum n
  | Bool b -> Value.vbool b
  | List r -> Value.oflist (List.map to_plugin_value !r)
  | Map _ ->
    let out = Value.vmap () in
    List.iter (fun k -> Value.set out k (to_plugin_value (getp v k))) (keysof v);
    out
  | _ -> Value.vnull

(* A live provider from a Func entry: asked the secret name, answers a Str
 * (hit), Null/Noval (miss), a {__err__} map or an exception (error). *)
let func_provider (fn : value) : Secret.provider =
  {
    Secret.lookup =
      (fun name ->
        match call_vfn fn (Str name) with
        | Str s -> Some s
        | Noval | Null -> None
        | Map _ as m when None <> get_str m "__err__" ->
          Secret.fail (match get_str m "__err__" with Some e -> e | None -> "")
        | other -> Secret.fail ("sekreto: custom provider answered a non-string: " ^ stringify other));
    describe = (fun () -> "custom");
  }

let trim_slashes_right (s : string) : string =
  let n = ref (String.length s) in
  while !n > 0 && s.[!n - 1] = '/' do decr n done;
  String.sub s 0 !n

let trim_slashes_left (s : string) : string =
  let n = String.length s and i = ref 0 in
  while !i < n && s.[!i] = '/' do incr i done;
  String.sub s !i (n - !i)

(* Build the feature. `plugins` are the plugin DEFINITIONS the model
 * selected for this feature, emitted by Config_ocaml from the catalogue's
 * active `plugin.def.ocaml` entries (`Sdk_config.feature_plugins "secrets"`).
 * Upstream sekreto's contract since the registry was retired: a kind not
 * passed here is unknown to this Sekreto, so the model's choice of plugin
 * groups IS the SDK's provider vocabulary. `transport` is the bundled
 * exchange transport of last resort, present only when a plugin group
 * needing one is active (see the header). *)
let make ?(plugins : Defs.definition list = [])
    ?(transport : (string -> value -> value) option) () : feature =
  let f = { f_name = "secrets"; f_version = "0.1.0"; f_active = true; f_options = Noval;
            f_init = (fun _ _ -> ()); f_hook = (fun _ _ -> ()) } in

  let client : sdk_client option ref = ref None in
  let secretname = ref "apikey" in
  let cache = ref true in
  let exchange : xchg option ref = ref None in
  let sek : Sekreto.t option ref = ref None in
  (* The FIRST refusal, kept for the gate. *)
  let initerr : string option ref = ref None in
  (* The RESOLVED credential (or the bought access token), held in feature
   * state and injected into each request at the seam - never written into
   * the shared options map. *)
  let cred = ref "" in
  (* The refresh credential the chain resolved, for every later purchase. *)
  let refresh = ref "" in

  let refuse (msg : string) =
    (match !initerr with None -> initerr := Some msg | Some _ -> ()) in

  let live_options () : value =
    match !client with Some c -> c.cl_options | None -> empty_map () in

  let bucket () : value =
    match !client with
    | Some c -> track_bucket c "secrets" (fun () ->
        jo [("resolves", Num 0.); ("refusals", Num 0.); ("buys", Num 0.); ("retries", Num 0.)])
    | None -> empty_map () in

  (* Rewrite the authorization header on THIS request from the resolved
   * credential, the way prepare_auth builds it: `auth: null` (Noval or a
   * stored Null - the documented way to send NO credential) means no
   * header, else options.auth.prefix + the token. *)
  let reauth (fetchdef : value) (token : string) : unit =
    match getp fetchdef "headers" with
    | Map _ as headers ->
      let opts = live_options () in
      (match getp opts "auth" with
       | Map _ ->
         let prefix = match getpath_s opts "auth.prefix" with Str s -> s | _ -> "" in
         setp headers "authorization" (Str (if prefix <> "" then prefix ^ " " ^ token else token))
       | _ -> ignore (delprop headers (Str "authorization")))
    | _ -> () in

  let spent (x : xchg) (res : value) : bool =
    match res with
    | Map _ -> (match getp res "status" with
        | Num n -> List.mem (int_of_float n) x.xstatuses
        | _ -> false)
    | _ -> false in

  (* One purchase, through the raw seam (options.system.fetch) or the
   * bundled transport. The body is JSON-MARSHALLED, never concatenated: a
   * refresh token carrying a quote, backslash or newline must arrive as
   * that literal value. Deliberately NOT the SDK transport: that is what
   * this feature wraps, and sending the token request back through it
   * would recurse on the first expiry - and route the exchange through
   * the test mock, which knows nothing about it. *)
  let buyonce (x : xchg) : (string, string) Stdlib.result =
    if "" = !refresh then
      Error ("secrets: no refresh token: the provider chain has no '" ^ !secretname
             ^ "', and feature.secrets.exchange.refresh is unset")
    else begin
      let opts = live_options () in
      let base = trim_slashes_right (match getp opts "base" with Str s -> s | _ -> "") in
      let url = base ^ "/" ^ trim_slashes_left x.xpath in
      let fetchdef = jo [
        ("method", Str x.xmethod);
        ("headers", jo [("content-type", Str "application/json")]);
        ("body", Str (jsonify (jo [(x.xrequest, Str !refresh)])))] in
      let fetch =
        match getpath_s opts "system.fetch" with
        | Func _ as sf -> Some (fun url fd -> call_vfn sf (ja [Str url; fd]))
        | _ -> transport in
      match fetch with
      | None ->
        Error ("secrets: the token exchange has no HTTP transport: this SDK's core bundles "
               ^ "none and no secrets plugin group needing one is active, so the vendored "
               ^ "HTTP client is not compiled; supply options.system.fetch or activate a "
               ^ "plugin group")
      | Some fetch ->
        (match fetch url fetchdef with
         | exception e -> Error (exn_message e)
         | res ->
           (match get_str res "__err__" with
            | Some m -> Error m
            | None ->
              let status = to_int (getp res "status") in
              if status < 200 || status >= 300 then
                Error ("secrets: token exchange failed: " ^ string_of_int status ^ " from " ^ url)
              else begin
                let body = match getp res "json" with
                  | Func _ as jf -> (try call_json jf with _ -> Noval)
                  | _ -> getp res "body" in
                let body = match body with
                  | Str s -> (try Sdk_json.json_read s with _ -> Noval)
                  | b -> b in
                match getp body x.xresponse with
                | Str t when "" <> t -> Ok t
                | _ -> Error ("secrets: token exchange returned no '" ^ x.xresponse
                              ^ "' field from " ^ url)
              end))
    end in

  (* Buy an access token with the refresh token. TEST MODE BUYS NOTHING:
   * the test feature replaces the transport so no request leaves the
   * process; an exchange here would be the one call it could not stop. A
   * deterministic, obviously-fake token instead - the same answer
   * make_options gives a required server variable, for the same reason. *)
  let buy (x : xchg) : (string, string) Stdlib.result =
    let mode = match !client with Some c -> c.cl_mode | None -> "live" in
    bump_num (bucket ()) "buys" 1.;
    if "live" <> mode then begin
      let t = "test-" ^ x.xresponse in
      cred := t;
      Ok t
    end
    else
      match buyonce x with
      | Ok t -> cred := t; Ok t
      | Error m -> Error m in

  (* One resolution. sekreto caches a hit itself when `cache` is on, so
   * asking it per request is the cost of a list walk; with `cache: false`
   * the chain is asked once per REQUEST, which is that option's meaning. A
   * provider ERROR is the caller's to refuse with; only a MISS falls
   * through. *)
  let resolve () : (unit, string) Stdlib.result =
    match !sek with
    | None -> Ok ()
    | Some s ->
      bump_num (bucket ()) "resolves" 1.;
      (match Sekreto.tryget s !secretname with
       | exception e -> Error (exn_message e)
       | found ->
         (match !exchange with
          | None ->
            (* An UNCACHED miss after an earlier hit is a revocation: the
             * chain now says no provider has the secret, so the resolved
             * value must not keep going out on the wire. (An explicit
             * apikey OPTION is never lost here - it seats FIRST in the
             * chain as a memory provider, so the chain HITS while one is
             * set and the miss branch is unreachable.) *)
            cred := (match found with Some v -> v | None -> "");
            Ok ()
          | Some x ->
            (* Exchanging: what the chain resolved is the REFRESH token. A
             * miss is not fatal here - an explicit `apikey` may already hold
             * a usable access token, and the API gets to say whether it
             * does: if it is stale the API answers with an expiry status
             * and the wrapper buys another, the same path expiry takes. *)
            refresh := (match found with Some v -> v | None -> "");
            if "" = !cred then
              cred := (match getp (live_options ()) "apikey" with Str s -> s | _ -> "");
            if "" <> !cred then Ok ()
            else (match buy x with Ok _ -> Ok () | Error m -> Error m))) in

  (* Buy a token and try the request again when the API says the current
   * one is spent. The retry rewrites the authorization header IN PLACE on
   * the fetchdef, because the header carries the token that just failed. *)
  let withrefresh (x : xchg) fctx url fetchdef inner : (value * sdk_error option) =
    (* `auth: null` is the documented way to send NO credential, and
     * prepare_auth honours it by removing the header. A refusal of a
     * deliberately unauthenticated request is not an expired token and
     * cannot be fixed by buying one. *)
    match getp (live_options ()) "auth" with
    | Noval | Null -> inner fctx url fetchdef
    | _ ->
      let rec attempt (n : int) =
        (* The credential THIS attempt goes out with, captured before it
         * leaves: it is what tells a stale refusal apart from a fresh one. *)
        let used = !cred in
        let (res, err) = inner fctx url fetchdef in
        if None <> err || n >= x.xretries || not (spent x res) then (res, err)
        else begin
          (* Another request may have bought a token while this one was in
           * flight (a threaded host): spend what is current before buying. *)
          let current = !cred in
          let token =
            if "" <> current && current <> used then Some current
            else (match buy x with Ok t -> Some t | Error _ -> None) in
          match token with
          (* The purchase failed: answer with the API's own refusal rather
           * than this one - the refusal is the more useful of the two. *)
          | None -> (res, err)
          | Some t ->
            reauth fetchdef t;
            bump_num (bucket ()) "retries" 1.;
            attempt (n + 1)
        end in
      attempt 0 in

  (* The transport wrapper: fail-closed, at the ONE seam every wire path
   * crosses. Entity ops, direct, graphql and the exchange retries all come
   * through here, so resolving HERE is what gives the raw paths - which run
   * no feature hooks - the same credential the entity pipeline gets. *)
  let transport fctx url fetchdef inner : (value * sdk_error option) =
    match !initerr with
    | Some msg ->
      bump_num (bucket ()) "refusals" 1.;
      (Noval, Some (ctx_make_error fctx "secrets_init" msg))
    | None ->
      (match resolve () with
       | Error msg ->
         bump_num (bucket ()) "refusals" 1.;
         (Noval, Some (ctx_make_error fctx "secrets_provider" msg))
       | Ok () ->
         if "" <> !cred then reauth fetchdef !cred;
         (match !exchange with
          | None -> inner fctx url fetchdef
          | Some x -> withrefresh x fctx url fetchdef inner)) in

  (* Init is sync by feature contract: build the chain, never look anything
   * up here. Construction contacts nothing - a provider opens nothing until
   * its first lookup. *)
  f.f_init <- (fun ctx opts ->
      let opts = match to_map opts with Map _ as m -> m | _ -> empty_map () in
      f.f_active <- opt_active opts;
      if f.f_active then begin
        let c = cc ctx in
        client := Some c;
        secretname := (let n = opt_str opts "name" ~default:"apikey" in if "" = n then "apikey" else n);
        cache := (getp opts "cache" <> Bool false);

        (* Exchange config, normalised once. None when off, so every later
         * decision is an option match. *)
        let xopts = match to_map (getp opts "exchange") with Map _ as m -> m | _ -> empty_map () in
        exchange :=
          (if opt_active xopts then begin
             let statuses = match getp xopts "statuses" with
               | List r -> List.filter_map (function Num n -> Some (int_of_float n) | _ -> None) !r
               | _ -> [] in
             Some {
               xpath = opt_str xopts "path" ~default:"auth/token";
               xmethod = opt_str xopts "method" ~default:"POST";
               xrequest = opt_str xopts "request" ~default:"refresh_token";
               xresponse = opt_str xopts "response" ~default:"access_token";
               xstatuses = (if [] = statuses then [401] else statuses);
               xretries = opt_int xopts "retries" ~default:1;
             }
           end else None);

        (* WRAP FIRST, before anything below can fail. The gate lives in
         * the wrapper, so a chain that cannot be built must still find it
         * installed - otherwise a construction failure would leave the
         * ORIGINAL transport in place and every request would go out
         * unauthenticated, the one outcome this feature exists to prevent.
         * Wrapping whatever transport is current at init also means the
         * exchange (when on) SEES responses, which is the only place expiry
         * is ever discovered. *)
        let u = cu ctx in
        let inner = u.u_fetcher in
        u.u_fetcher <- (fun fctx url fd -> transport fctx url fd inner);

        (* The explicit credential, when set, is the first store in the
         * chain. WHICH option that is depends on the exchange: without one
         * the secret being resolved IS the credential the transport sends,
         * so `apikey` is it; with one, the secret is a REFRESH token and
         * `apikey` means the opposite thing - an access token the caller
         * already holds - so the explicit seat belongs to `exchange.refresh`
         * and apikey is left alone to serve as the starting access token. *)
        let explicit = match !exchange with
          | None -> (match getp c.cl_options "apikey" with Str s -> s | _ -> "")
          | Some _ -> (match getp xopts "refresh" with Str s -> s | _ -> "") in

        let specs : Provider.spec list ref = ref [] in
        let synthesized : Defs.definition list ref = ref [] in

        if "" <> explicit then begin
          match Secret.envkey !secretname with
          | key ->
            specs := [ { Provider.nospec with Provider.kind = "memory"; name = "options";
                         values = [ (key, explicit) ] } ]
          (* An invalid secret `name` is a misconfiguration, and sekreto's
           * own message says which. Refused at the gate rather than skipped. *)
          | exception e -> refuse (exn_message e)
        end;

        (* The chain, entry by entry - see the header for the three shapes.
         * A list hole (Null) is refused like any other non-provider, so it
         * cannot end the chain early. *)
        (match getp opts "providers" with
         | Noval -> ()
         | List r ->
           List.iteri (fun i entry ->
               match entry with
               | Map _ -> specs := !specs @ [ Provider.specof (to_plugin_value entry) ]
               | Func _ ->
                 let kind = "custom" ^ string_of_int (i + 1) in
                 synthesized := !synthesized @ [ Provider.providerplugin kind (fun _ -> func_provider entry) ];
                 specs := !specs @ [ { Provider.nospec with Provider.kind = kind; name = "custom" } ]
               | other ->
                 refuse ("sekreto: not a provider or a provider spec: " ^ stringify other))
             !r
         | other -> refuse ("sekreto: not a provider or a provider spec: " ^ stringify other));

        (* A refusal here (unknown kind, a plugin kind not passed in, a spec
         * the kind rejects) is kept for the gate. *)
        (match Sekreto.sekreto ~cache:!cache ~plugins:(plugins @ !synthesized) !specs with
         | s -> sek := Some s
         | exception e -> refuse (exn_message e))
      end);
  f
