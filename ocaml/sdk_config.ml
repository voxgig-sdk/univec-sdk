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
      ("version", (Str "0.1.2"));
      ("target", (Str "ocaml")) ]));
    ("feature", (jo [
      ("audit", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("actor", (Str "anonymous"));
          ("max", (Num (1000.))) ]));
        ("optspec", (jo [
          ("now", (Str "`$FUNCTION`"));
          ("sink", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "none")) ]));
      ("cache", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("max", (Num (256.)));
          ("methods", (ja [
            (Str "GET") ]));
          ("ttl", (Num (5000.))) ]));
        ("optspec", (jo [
          ("now", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "wrap")) ]));
      ("clienttrack", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("clientVersion", (Str "0.0.1")) ]));
        ("optspec", (jo [
          ("clientName", (Str "`$STRING`"));
          ("clientVersion", (Str "`$STRING`"));
          ("headers", (Str "`$MAP`"));
          ("idgen", (Str "`$FUNCTION`"));
          ("sessionId", (Str "`$STRING`")) ]));
        ("strict", (Bool false));
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
        ("optspec", (jo [
          ("actor", (Str "`$STRING`"));
          ("sink", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
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
        ("optspec", (jo [
          ("now", (Str "`$FUNCTION`"));
          ("onEntry", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
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
        ("optspec", (jo [
          ("keygen", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "none")) ]));
      ("log", (jo [
        ("options", (jo [
          ("active", (Bool true)) ]));
        ("optspec", (jo [
          ("level", (Str "`$STRING`"));
          ("logger", (Str "`$ANY`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "none")) ]));
      ("metrics", (jo [
        ("options", (jo [
          ("active", (Bool false)) ]));
        ("optspec", (jo [
          ("now", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
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
        ("optspec", (jo [
          ("latency", (ja [
            (Str "`$ONE`");
            (Str "`$NUMBER`");
            (Str "`$MAP`") ]));
          ("sleep", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
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
        ("optspec", (jo [
          ("limit", (Str "`$NUMBER`"));
          ("ops", (Str "`$LIST`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "none")) ]));
      ("proxy", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("fromEnv", (Bool false));
          ("noProxy", (empty_list ()));
          ("url", (Str "")) ]));
        ("optspec", (jo [
          ("agent", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "wrap")) ]));
      ("ratelimit", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("burst", (Num (5.)));
          ("rate", (Num (5.))) ]));
        ("optspec", (jo [
          ("now", (Str "`$FUNCTION`"));
          ("sleep", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "wrap")) ]));
      ("rbac", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("deny", (Bool false));
          ("permissions", (empty_list ()));
          ("rules", (empty_map ())) ]));
        ("optspec", (empty_map ()));
        ("strict", (Bool false));
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
        ("optspec", (jo [
          ("jitter", (Str "`$BOOLEAN`"));
          ("sleep", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "wrap")) ]));
      ("secrets", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("cache", (Bool true));
          ("exchange", (jo [
            ("active", (Bool false));
            ("method", (Str "POST"));
            ("path", (Str "auth/token"));
            ("refresh", (Str ""));
            ("request", (Str "refresh_token"));
            ("response", (Str "access_token"));
            ("retries", (Num (1.)));
            ("statuses", (ja [
              (Num (401.)) ])) ]));
          ("name", (Str "univec"));
          ("providers", (ja [
            (jo [
              ("kind", (Str "boru"));
              ("namespace", (Str "sdk")) ]) ])) ]));
        ("optspec", (empty_map ()));
        ("strict", (Bool false));
        ("transport", (Str "wrap")) ]));
      ("streaming", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("chunkDelay", (Num (0.)));
          ("chunkSize", (Num (0.))) ]));
        ("optspec", (jo [
          ("ops", (Str "`$LIST`"));
          ("sleep", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "none")) ]));
      ("telemetry", (jo [
        ("options", (jo [
          ("active", (Bool false)) ]));
        ("optspec", (jo [
          ("exporter", (Str "`$FUNCTION`"));
          ("headers", (Str "`$MAP`"));
          ("idgen", (Str "`$FUNCTION`"));
          ("now", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "none")) ]));
      ("test", (jo [
        ("options", (jo [
          ("active", (Bool false)) ]));
        ("optspec", (jo [
          ("entity", (Str "`$MAP`"));
          ("net", (Str "`$MAP`")) ]));
        ("strict", (Bool false));
        ("transport", (Str "base")) ]));
      ("timeout", (jo [
        ("options", (jo [
          ("active", (Bool false));
          ("ms", (Num (30000.))) ]));
        ("optspec", (jo [
          ("clearTimer", (Str "`$FUNCTION`"));
          ("setTimer", (Str "`$FUNCTION`")) ]));
        ("strict", (Bool false));
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
            ("type", (Str "`$STRING`")) ]) ]));
        ("name", (Str "convert"));
        ("op", (jo [
          ("create", (jo [
            ("input", (Str "data"));
            ("name", (Str "create"));
            ("points", (ja [
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("live", (jo [
                  ("assert", (jo [
                    ("equal", (jo [
                      ("source_model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "sourceModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("target_model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "targetModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ])) ]));
                    ("vectors", (jo [
                      ("count", (Num (1.)));
                      ("dimension", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "targetDim"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("path", (Str "embeddings")) ])) ]));
                  ("auth", (Str "account"));
                  ("id", (Str "account-convert"));
                  ("input", (jo [
                    ("embeddings", (jo [
                      ("from", (Str "account-embed"));
                      ("path", (Str "embeddings")) ]));
                    ("source_model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "sourceModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ]));
                    ("target_model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "targetModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ])) ])) ]));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/convert"));
                ("segments", (ja [
                  (jo [
                    ("lit", (Str "v1")) ]);
                  (jo [
                    ("lit", (Str "convert")) ]) ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ]));
                ("parts", (ja [
                  (Str "v1");
                  (Str "convert") ])) ]);
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("live", (jo [
                  ("assert", (jo [
                    ("equal", (jo [
                      ("bridge_model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "sourceModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("target_model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "targetModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ])) ]));
                    ("vectors", (jo [
                      ("count", (Num (1.)));
                      ("dimension", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "targetDim"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("path", (Str "embeddings")) ])) ]));
                  ("auth", (Str "account"));
                  ("id", (Str "account-embed-bridge"));
                  ("input", (jo [
                    ("bridge_model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "sourceModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ]));
                    ("target_model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "targetModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ]));
                    ("texts", (ja [
                      (Str "SDK live coverage test.") ])) ])) ]));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/embed-bridge"));
                ("segments", (ja [
                  (jo [
                    ("lit", (Str "v1")) ]);
                  (jo [
                    ("lit", (Str "embed-bridge")) ]) ]));
                ("select", (jo [
                  ("$action", (Str "bridge")) ]));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ]));
                ("parts", (ja [
                  (Str "v1");
                  (Str "embed-bridge") ])) ]);
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("live", (jo [
                  ("assert", (jo [
                    ("equal", (jo [
                      ("source_model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "sourceModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("target_model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "targetModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ])) ]));
                    ("vectors", (jo [
                      ("count", (Num (1.)));
                      ("dimension", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "targetDim"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("path", (Str "embeddings")) ])) ]));
                  ("auth", (Str "issued"));
                  ("credential", (jo [
                    ("from", (Str "key"));
                    ("path", (Str "key")) ]));
                  ("id", (Str "ephemeral-convert"));
                  ("input", (jo [
                    ("embeddings", (jo [
                      ("from", (Str "ephemeral-embed"));
                      ("path", (Str "embeddings")) ]));
                    ("source_model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "sourceModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ]));
                    ("target_model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "targetModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ])) ])) ]));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/ephemeral/convert"));
                ("segments", (ja [
                  (jo [
                    ("lit", (Str "v1")) ]);
                  (jo [
                    ("lit", (Str "ephemeral")) ]);
                  (jo [
                    ("lit", (Str "convert")) ]) ]));
                ("select", (jo [
                  ("$action", (Str "ephemeral")) ]));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ]));
                ("parts", (ja [
                  (Str "v1");
                  (Str "ephemeral");
                  (Str "convert") ])) ]);
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("live", (jo [
                  ("assert", (jo [
                    ("equal", (jo [
                      ("bridge_model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "sourceModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("target_model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "targetModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ])) ]));
                    ("vectors", (jo [
                      ("count", (Num (1.)));
                      ("dimension", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "targetDim"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("path", (Str "embeddings")) ])) ]));
                  ("auth", (Str "issued"));
                  ("credential", (jo [
                    ("from", (Str "key"));
                    ("path", (Str "key")) ]));
                  ("id", (Str "ephemeral-embed-bridge"));
                  ("input", (jo [
                    ("bridge_model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "sourceModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ]));
                    ("target_model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "targetModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ]));
                    ("texts", (ja [
                      (Str "SDK live coverage test.") ])) ])) ]));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/ephemeral/embed-bridge"));
                ("segments", (ja [
                  (jo [
                    ("lit", (Str "v1")) ]);
                  (jo [
                    ("lit", (Str "ephemeral")) ]);
                  (jo [
                    ("lit", (Str "embed-bridge")) ]) ]));
                ("select", (jo [
                  ("$action", (Str "ephemeral_bridge")) ]));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ]));
                ("parts", (ja [
                  (Str "v1");
                  (Str "ephemeral");
                  (Str "embed-bridge") ])) ]) ])) ])) ]));
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
                ("live", (jo [
                  ("assert", (jo [
                    ("equal", (jo [
                      ("model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "sourceModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ])) ]));
                    ("vectors", (jo [
                      ("count", (Num (1.)));
                      ("dimension", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "sourceDim"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("path", (Str "embeddings")) ])) ]));
                  ("auth", (Str "account"));
                  ("id", (Str "account-embed"));
                  ("input", (jo [
                    ("model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "sourceModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ]));
                    ("texts", (ja [
                      (Str "SDK live coverage test.") ])) ])) ]));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/embed"));
                ("segments", (ja [
                  (jo [
                    ("lit", (Str "v1")) ]);
                  (jo [
                    ("lit", (Str "embed")) ]) ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ]));
                ("parts", (ja [
                  (Str "v1");
                  (Str "embed") ])) ]);
              (jo [
                ("args", (empty_map ()));
                ("kind", (Str "http"));
                ("live", (jo [
                  ("assert", (jo [
                    ("equal", (jo [
                      ("model", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "sourceModel"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ])) ]));
                    ("vectors", (jo [
                      ("count", (Num (1.)));
                      ("dimension", (jo [
                        ("from", (Str "models"));
                        ("path", (Str "sourceDim"));
                        ("related", (jo [
                          ("foreign", (Str "name"));
                          ("from", (Str "models"));
                          ("local", (Str "sourceModel"));
                          ("where", (jo [
                            ("modelType", (Str "embed")) ])) ]));
                        ("where", (jo [
                          ("modelType", (Str "convert")) ])) ]));
                      ("path", (Str "embeddings")) ])) ]));
                  ("auth", (Str "issued"));
                  ("credential", (jo [
                    ("from", (Str "key"));
                    ("path", (Str "key")) ]));
                  ("id", (Str "ephemeral-embed"));
                  ("input", (jo [
                    ("model", (jo [
                      ("from", (Str "models"));
                      ("path", (Str "sourceModel"));
                      ("related", (jo [
                        ("foreign", (Str "name"));
                        ("from", (Str "models"));
                        ("local", (Str "sourceModel"));
                        ("where", (jo [
                          ("modelType", (Str "embed")) ])) ]));
                      ("where", (jo [
                        ("modelType", (Str "convert")) ])) ]));
                    ("texts", (ja [
                      (Str "SDK live coverage test.") ])) ])) ]));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/ephemeral/embed"));
                ("segments", (ja [
                  (jo [
                    ("lit", (Str "v1")) ]);
                  (jo [
                    ("lit", (Str "ephemeral")) ]);
                  (jo [
                    ("lit", (Str "embed")) ]) ]));
                ("select", (jo [
                  ("$action", (Str "ephemeral")) ]));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ]));
                ("parts", (ja [
                  (Str "v1");
                  (Str "ephemeral");
                  (Str "embed") ])) ]) ])) ])) ]));
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
            ("format", (Str "date-time"));
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
                ("live", (jo [
                  ("assert", (jo [
                    ("nonempty", (ja [
                      (Str "key") ])) ]));
                  ("auth", (Str "public"));
                  ("id", (Str "key"));
                  ("retention", (Str "No deletion endpoint; issued key is subject to the service daily allowance")) ]));
                ("method", (Str "POST"));
                ("orig", (Str "/v1/ephemeral/key"));
                ("segments", (ja [
                  (jo [
                    ("lit", (Str "v1")) ]);
                  (jo [
                    ("lit", (Str "ephemeral")) ]);
                  (jo [
                    ("lit", (Str "key")) ]) ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ]));
                ("parts", (ja [
                  (Str "v1");
                  (Str "ephemeral");
                  (Str "key") ])) ]) ])) ])) ]));
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
                ("live", (jo [
                  ("assert", (jo [
                    ("nonempty", (ja [
                      (Str "") ])) ]));
                  ("auth", (Str "public"));
                  ("id", (Str "models")) ]));
                ("method", (Str "GET"));
                ("orig", (Str "/v1/models"));
                ("segments", (ja [
                  (jo [
                    ("lit", (Str "v1")) ]);
                  (jo [
                    ("lit", (Str "models")) ]) ]));
                ("select", (empty_map ()));
                ("transform", (jo [
                  ("req", (Str "`reqdata`"));
                  ("res", (Str "`body.data`")) ]));
                ("parts", (ja [
                  (Str "v1");
                  (Str "models") ])) ]) ])) ])) ]));
        ("relations", (jo [
          ("ancestors", (empty_list ())) ])) ])) ])) ])

(* The plugin definitions the model selected for the secrets feature's
 * provider chain (plugin groups: vault).
 * Built, not held: every call is a fresh list, so two chains never share
 * a definition. *)
let feature_plugins (name : string) : Defs.definition list =
  match name with
  | "secrets" -> [
      Boru.plugin ();
      Hashicorp.plugin ();
    ]
  | _ -> []

(* The token-exchange transport of last resort: the vendored sekreto HTTP
 * client (plugins/http.ml over plugins/tls.ml), compiled because a plugin
 * group needing a transport is active (vault).
 * A network failure raises sekreto's own Sekreto_error, which the feature
 * reports as the refusal. *)
let secrets_transport (url : string) (fetchdef : value) : value =
  let meth = match getp fetchdef "method" with Str s -> s | _ -> "POST" in
  let headers = match getp fetchdef "headers" with
    | Map _ as h ->
      List.filter_map (fun k -> match getp h k with Str v -> Some (k, v) | _ -> None) (keysof h)
    | _ -> [] in
  let body = match getp fetchdef "body" with Str s -> Some s | _ -> None in
  let res = Http.request meth url headers body in
  let text = res.Http.body in
  jo [("status", Num (float_of_int res.Http.status));
      ("statusText", Str (if res.Http.status >= 400 then "ERR" else "OK"));
      ("headers", empty_map ());
      ("body", Str text);
      ("json", json_thunk (try Sdk_json.json_read text with _ -> Noval))]

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
  | "secrets" -> Secrets_feature.make ~plugins:(feature_plugins "secrets") ~transport:secrets_transport ()
  | _ -> base_feature ()
