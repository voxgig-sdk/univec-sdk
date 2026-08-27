(* Generated API configuration (mirrors go core/config.go).
 *
 * make_config () — the embedded API model as a voxgig struct value.
 * make_feature name — the N-feature-safe factory the client uses. *)

open Voxgig_struct
open Sdk_types
open Sdk_helpers
open Sdk_features

let make_config () : value =
  (jo [
    ("main", (jo [
      ("name", (Str "Univec"));
      ("slug", (Str "univec"));
      ("version", (Str "0.1.1"));
      ("target", (Str "ocaml")) ]));
    ("feature", (jo [
      ("audit", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("actor", (Str "anonymous"));
          ("max", (Num (1000.))) ]));
        ("transport", (Str "none")) ]));
      ("cache", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("max", (Num (256.)));
          ("methods", (ja [
            (Str "GET") ]));
          ("ttl", (Num (5000.))) ]));
        ("transport", (Str "wrap")) ]));
      ("clienttrack", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("clientVersion", (Str "0.0.1")) ]));
        ("transport", (Str "none")) ]));
      ("cost", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("budget", (Num (0.)));
          ("currency", (Str "USD"));
          ("header", (Str ""));
          ("onBudget", (Str "warn"));
          ("path", (Str ""));
          ("perUnit", (Num (0.)));
          ("rates", (empty_map ()));
          ("unit", (Num (0.))) ]));
        ("transport", (Str "wrap")) ]));
      ("debug", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("max", (Num (100.)));
          ("redact", (ja [
            (Str "authorization");
            (Str "cookie");
            (Str "set-cookie");
            (Str "api-key");
            (Str "apikey");
            (Str "x-api-key");
            (Str "idempotency-key") ])) ]));
        ("transport", (Str "none")) ]));
      ("idempotency", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("header", (Str "Idempotency-Key"));
          ("methods", (ja [
            (Str "POST");
            (Str "PUT");
            (Str "PATCH");
            (Str "DELETE") ]));
          ("ops", (ja [
            (Str "create");
            (Str "update");
            (Str "remove") ])) ]));
        ("transport", (Str "none")) ]));
      ("log", (jo [
        ("options", (jo [
          ("active", (Bool true)) ]));
        ("transport", (Str "none")) ]));
      ("metrics", (jo [
        ("options", (jo [
          ("active", (Bool false)) ]));
        ("transport", (Str "none")) ]));
      ("netsim", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("errorTimes", (Num (0.)));
          ("failEvery", (Num (0.)));
          ("failRate", (Num (0.)));
          ("failStatus", (Num (503.)));
          ("failTimes", (Num (0.)));
          ("latency", (Num (0.)));
          ("offline", (Bool false));
          ("rateLimitTimes", (Num (0.)));
          ("retryAfter", (Num (0.)));
          ("seed", (Num (1.))) ]));
        ("transport", (Str "wrap")) ]));
      ("paging", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("afterVar", (Str "after"));
          ("cursorParam", (Str "cursor"));
          ("firstVar", (Str "first"));
          ("limitParam", (Str "limit"));
          ("pageParam", (Str "page"));
          ("startPage", (Num (1.))) ]));
        ("transport", (Str "none")) ]));
      ("proxy", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("fromEnv", (Bool false));
          ("noProxy", (empty_list ()));
          ("url", (Str "")) ]));
        ("transport", (Str "wrap")) ]));
      ("ratelimit", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("burst", (Num (5.)));
          ("rate", (Num (5.))) ]));
        ("transport", (Str "wrap")) ]));
      ("rbac", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("deny", (Bool false));
          ("permissions", (empty_list ()));
          ("rules", (empty_map ())) ]));
        ("transport", (Str "none")) ]));
      ("retry", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("factor", (Num (2.)));
          ("maxDelay", (Num (2000.)));
          ("minDelay", (Num (50.)));
          ("retries", (Num (2.)));
          ("statuses", (ja [
            (Num (408.));
            (Num (425.));
            (Num (429.));
            (Num (500.));
            (Num (502.));
            (Num (503.));
            (Num (504.)) ])) ]));
        ("transport", (Str "wrap")) ]));
      ("streaming", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("chunkDelay", (Num (0.)));
          ("chunkSize", (Num (0.))) ]));
        ("transport", (Str "none")) ]));
      ("telemetry", (jo [
        ("options", (jo [
          ("active", (Bool false)) ]));
        ("transport", (Str "none")) ]));
      ("test", (jo [
        ("options", (jo [
          ("active", (Bool false)) ]));
        ("transport", (Str "base")) ]));
      ("timeout", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("ms", (Num (30000.))) ]));
        ("transport", (Str "wrap")) ])) ]));
    ("options", (jo [
      ("base", (Str "https://api.univec.ai"));
      ("auth", (jo [
        ("prefix", (Str "Bearer")) ]));
      ("headers", (jo [
        ("content-type", (Str "application/json")) ]));
      ("entity", (jo [
        ("convert", (empty_map ()));
        ("embed", (empty_map ()));
        ("ephemeral_key", (empty_map ()));
        ("model", (empty_map ())) ])) ]));
    ("entity", (jo [
      ("convert", (jo [
        ("fields", (ja [
          (jo [
            ("name", (Str "bridge_model"));
            ("req", (Bool true));
            ("short", (Str "Embed model used to vectorise the text before translation."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "embeddings"));
            ("req", (Bool true));
            ("short", (Str "Translated vectors, in the target model's dimension."));
            ("type", (Str "`$ARRAY`")) ]);
          (jo [
            ("name", (Str "source_model"));
            ("req", (Bool true));
            ("short", (Str "Model space the supplied vectors are currently in."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "target_model"));
            ("req", (Bool true));
            ("short", (Str "Model space to translate into."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "texts"));
            ("req", (Bool true));
            ("short", (Str "Texts to embed and translate."));
            ("type", (Str "`$ARRAY`")) ]) ]));
        ("name", (Str "convert"));
        ("op", (jo [
          ("create", (jo [
            ("input", (Str "data"));
            ("name", (Str "create"));
            ("points", (ja [
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/convert"));
                ("parts", (ja [
                  (Str "v1");
                  (Str "convert") ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ])) ]);
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/embed-bridge"));
                ("parts", (ja [
                  (Str "v1");
                  (Str "embed-bridge") ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ])) ]);
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/ephemeral/convert"));
                ("parts", (ja [
                  (Str "v1");
                  (Str "ephemeral");
                  (Str "convert") ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ])) ]);
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/ephemeral/embed-bridge"));
                ("parts", (ja [
                  (Str "v1");
                  (Str "ephemeral");
                  (Str "embed-bridge") ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ])) ]) ])) ])) ]));
        ("relations", (jo [
          ("ancestors", (empty_list ())) ])) ]));
      ("embed", (jo [
        ("fields", (ja [
          (jo [
            ("name", (Str "embeddings"));
            ("req", (Bool true));
            ("short", (Str "One vector per input text, in input order."));
            ("type", (Str "`$ARRAY`")) ]);
          (jo [
            ("name", (Str "model"));
            ("req", (Bool true));
            ("short", (Str "Model that produced the vectors."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "texts"));
            ("req", (Bool true));
            ("short", (Str "Texts to embed."));
            ("type", (Str "`$ARRAY`")) ]) ]));
        ("name", (Str "embed"));
        ("op", (jo [
          ("create", (jo [
            ("input", (Str "data"));
            ("name", (Str "create"));
            ("points", (ja [
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/embed"));
                ("parts", (ja [
                  (Str "v1");
                  (Str "embed") ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ])) ]);
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/ephemeral/embed"));
                ("parts", (ja [
                  (Str "v1");
                  (Str "ephemeral");
                  (Str "embed") ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ])) ]) ])) ])) ]));
        ("relations", (jo [
          ("ancestors", (empty_list ())) ])) ]));
      ("ephemeral_key", (jo [
        ("fields", (ja [
          (jo [
            ("name", (Str "dailyLimit"));
            ("req", (Bool true));
            ("short", (Str "Calls permitted per day."));
            ("type", (Str "`$INTEGER`")) ]);
          (jo [
            ("name", (Str "dailyUsed"));
            ("req", (Bool true));
            ("short", (Str "Calls already used today."));
            ("type", (Str "`$INTEGER`")) ]);
          (jo [
            ("name", (Str "key"));
            ("req", (Bool true));
            ("short", (Str "The ephemeral API key, prefixed `eph_`."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "resetsAt"));
            ("req", (Bool true));
            ("short", (Str "When the daily allowance resets."));
            ("type", (Str "`$STRING`")) ]) ]));
        ("name", (Str "ephemeral_key"));
        ("op", (jo [
          ("create", (jo [
            ("input", (Str "data"));
            ("name", (Str "create"));
            ("points", (ja [
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/ephemeral/key"));
                ("parts", (ja [
                  (Str "v1");
                  (Str "ephemeral");
                  (Str "key") ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ])) ]) ])) ])) ]));
        ("relations", (jo [
          ("ancestors", (empty_list ())) ])) ]));
      ("model", (jo [
        ("fields", (ja [
          (jo [
            ("name", (Str "eval"));
            ("short", (Str "Retrieval-fidelity metrics for a convert model."));
            ("type", (Str "`$OBJECT`")) ]);
          (jo [
            ("name", (Str "executionProvider"));
            ("short", (Str "Hardware backend, e.g."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "modelCard"));
            ("short", (Str "Convert models only: training provenance and architecture detail."));
            ("type", (Str "`$OBJECT`")) ]);
          (jo [
            ("name", (Str "modelType"));
            ("req", (Bool true));
            ("short", (Str "`embed` for text-to-vector models, `convert` for space-translation models."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "name"));
            ("req", (Bool true));
            ("short", (Str "Model identifier used in requests."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "sequenceLen"));
            ("short", (Str "Embed models only: maximum input sequence length."));
            ("type", (Str "`$INTEGER`")) ]);
          (jo [
            ("name", (Str "sourceDim"));
            ("short", (Str "Convert models only: source vector dimension."));
            ("type", (Str "`$INTEGER`")) ]);
          (jo [
            ("name", (Str "sourceModel"));
            ("short", (Str "Convert models only: the source model space."));
            ("type", (Str "`$STRING`")) ]);
          (jo [
            ("name", (Str "targetDim"));
            ("req", (Bool true));
            ("short", (Str "Dimension of the produced vectors."));
            ("type", (Str "`$INTEGER`")) ]);
          (jo [
            ("name", (Str "targetModel"));
            ("req", (Bool true));
            ("short", (Str "The model space produced."));
            ("type", (Str "`$STRING`")) ]) ]));
        ("name", (Str "model"));
        ("op", (jo [
          ("list", (jo [
            ("input", (Str "data"));
            ("name", (Str "list"));
            ("points", (ja [
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("method", (Str "GET"));
                ("orig", (Str "/v1/models"));
                ("parts", (ja [
                  (Str "v1");
                  (Str "models") ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ])) ]) ])) ])) ]));
        ("relations", (jo [
          ("ancestors", (empty_list ())) ])) ])) ])) ])

let make_feature (name : string) : feature =
  match name with
  | "audit" -> audit_feature ()
  | "cache" -> cache_feature ()
  | "clienttrack" -> clienttrack_feature ()
  | "cost" -> cost_feature ()
  | "debug" -> debug_feature ()
  | "idempotency" -> idempotency_feature ()
  | "log" -> log_feature ()
  | "metrics" -> metrics_feature ()
  | "netsim" -> netsim_feature ()
  | "paging" -> paging_feature ()
  | "proxy" -> proxy_feature ()
  | "ratelimit" -> ratelimit_feature ()
  | "rbac" -> rbac_feature ()
  | "retry" -> retry_feature ()
  | "streaming" -> streaming_feature ()
  | "telemetry" -> telemetry_feature ()
  | "test" -> test_feature ()
  | "timeout" -> timeout_feature ()
  | _ -> base_feature ()
