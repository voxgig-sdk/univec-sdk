// Generated API configuration (mirrors go core/config.go).

use std::cell::RefCell;
use std::rc::Rc;

use crate::core::types::FeatureRef;
use crate::utility::voxgigstruct::Value;

pub fn make_config() -> Value {
    Value::map_of([
        ("main".to_string(), Value::map_of([
            ("name".to_string(), Value::str("Univec")),
            ("slug".to_string(), Value::str("univec")),
            ("version".to_string(), Value::str("0.1.2")),
            ("target".to_string(), Value::str("rust")),
        ])),
        ("feature".to_string(), Value::map_of([
            ("audit".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("actor".to_string(), Value::str("anonymous")),
                    ("max".to_string(), Value::Num(1000f64)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("now".to_string(), Value::str("`$FUNCTION`")),
                    ("sink".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("cache".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("max".to_string(), Value::Num(256f64)),
                    ("methods".to_string(), Value::list(vec![
                        Value::str("GET"),
                    ])),
                    ("ttl".to_string(), Value::Num(5000f64)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("now".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("wrap")),
            ])),
            ("clienttrack".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("clientVersion".to_string(), Value::str("0.0.1")),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("clientName".to_string(), Value::str("`$STRING`")),
                    ("clientVersion".to_string(), Value::str("`$STRING`")),
                    ("headers".to_string(), Value::str("`$MAP`")),
                    ("idgen".to_string(), Value::str("`$FUNCTION`")),
                    ("sessionId".to_string(), Value::str("`$STRING`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("cost".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("budget".to_string(), Value::Num(0f64)),
                    ("currency".to_string(), Value::str("USD")),
                    ("header".to_string(), Value::str("")),
                    ("onBudget".to_string(), Value::str("warn")),
                    ("path".to_string(), Value::str("")),
                    ("perUnit".to_string(), Value::Num(0f64)),
                    ("rates".to_string(), Value::empty_map()),
                    ("unit".to_string(), Value::Num(0f64)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("actor".to_string(), Value::str("`$STRING`")),
                    ("sink".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("wrap")),
            ])),
            ("debug".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("max".to_string(), Value::Num(100f64)),
                    ("redact".to_string(), Value::list(vec![
                        Value::str("authorization"),
                        Value::str("cookie"),
                        Value::str("set-cookie"),
                        Value::str("api-key"),
                        Value::str("apikey"),
                        Value::str("x-api-key"),
                        Value::str("idempotency-key"),
                    ])),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("now".to_string(), Value::str("`$FUNCTION`")),
                    ("onEntry".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("idempotency".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("header".to_string(), Value::str("Idempotency-Key")),
                    ("methods".to_string(), Value::list(vec![
                        Value::str("POST"),
                        Value::str("PUT"),
                        Value::str("PATCH"),
                        Value::str("DELETE"),
                    ])),
                    ("ops".to_string(), Value::list(vec![
                        Value::str("create"),
                        Value::str("update"),
                        Value::str("remove"),
                    ])),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("keygen".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("log".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(true)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("level".to_string(), Value::str("`$STRING`")),
                    ("logger".to_string(), Value::str("`$ANY`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("metrics".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("now".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("netsim".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("errorTimes".to_string(), Value::Num(0f64)),
                    ("failEvery".to_string(), Value::Num(0f64)),
                    ("failRate".to_string(), Value::Num(0f64)),
                    ("failStatus".to_string(), Value::Num(503f64)),
                    ("failTimes".to_string(), Value::Num(0f64)),
                    ("latency".to_string(), Value::Num(0f64)),
                    ("offline".to_string(), Value::Bool(false)),
                    ("rateLimitTimes".to_string(), Value::Num(0f64)),
                    ("retryAfter".to_string(), Value::Num(0f64)),
                    ("seed".to_string(), Value::Num(1f64)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("latency".to_string(), Value::list(vec![
                        Value::str("`$ONE`"),
                        Value::str("`$NUMBER`"),
                        Value::str("`$MAP`"),
                    ])),
                    ("sleep".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("wrap")),
            ])),
            ("paging".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("afterVar".to_string(), Value::str("after")),
                    ("cursorParam".to_string(), Value::str("cursor")),
                    ("firstVar".to_string(), Value::str("first")),
                    ("limitParam".to_string(), Value::str("limit")),
                    ("pageParam".to_string(), Value::str("page")),
                    ("startPage".to_string(), Value::Num(1f64)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("limit".to_string(), Value::str("`$NUMBER`")),
                    ("ops".to_string(), Value::str("`$LIST`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("proxy".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("fromEnv".to_string(), Value::Bool(false)),
                    ("noProxy".to_string(), Value::empty_list()),
                    ("url".to_string(), Value::str("")),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("agent".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("wrap")),
            ])),
            ("ratelimit".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("burst".to_string(), Value::Num(5f64)),
                    ("rate".to_string(), Value::Num(5f64)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("now".to_string(), Value::str("`$FUNCTION`")),
                    ("sleep".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("wrap")),
            ])),
            ("rbac".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("deny".to_string(), Value::Bool(false)),
                    ("permissions".to_string(), Value::empty_list()),
                    ("rules".to_string(), Value::empty_map()),
                ])),
                ("optspec".to_string(), Value::empty_map()),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("retry".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("factor".to_string(), Value::Num(2f64)),
                    ("maxDelay".to_string(), Value::Num(2000f64)),
                    ("minDelay".to_string(), Value::Num(50f64)),
                    ("retries".to_string(), Value::Num(2f64)),
                    ("statuses".to_string(), Value::list(vec![
                        Value::Num(408f64),
                        Value::Num(425f64),
                        Value::Num(429f64),
                        Value::Num(500f64),
                        Value::Num(502f64),
                        Value::Num(503f64),
                        Value::Num(504f64),
                    ])),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("jitter".to_string(), Value::str("`$BOOLEAN`")),
                    ("sleep".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("wrap")),
            ])),
            ("secrets".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("cache".to_string(), Value::Bool(true)),
                    ("exchange".to_string(), Value::map_of([
                        ("active".to_string(), Value::Bool(false)),
                        ("method".to_string(), Value::str("POST")),
                        ("path".to_string(), Value::str("auth/token")),
                        ("refresh".to_string(), Value::str("")),
                        ("request".to_string(), Value::str("refresh_token")),
                        ("response".to_string(), Value::str("access_token")),
                        ("retries".to_string(), Value::Num(1f64)),
                        ("statuses".to_string(), Value::list(vec![
                            Value::Num(401f64),
                        ])),
                    ])),
                    ("name".to_string(), Value::str("univec")),
                    ("providers".to_string(), Value::list(vec![
                        Value::map_of([
                            ("kind".to_string(), Value::str("boru")),
                            ("namespace".to_string(), Value::str("sdk")),
                        ]),
                    ])),
                ])),
                ("optspec".to_string(), Value::empty_map()),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("wrap")),
            ])),
            ("streaming".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("chunkDelay".to_string(), Value::Num(0f64)),
                    ("chunkSize".to_string(), Value::Num(0f64)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("ops".to_string(), Value::str("`$LIST`")),
                    ("sleep".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("telemetry".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("exporter".to_string(), Value::str("`$FUNCTION`")),
                    ("headers".to_string(), Value::str("`$MAP`")),
                    ("idgen".to_string(), Value::str("`$FUNCTION`")),
                    ("now".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("none")),
            ])),
            ("test".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("entity".to_string(), Value::str("`$MAP`")),
                    ("net".to_string(), Value::str("`$MAP`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("base")),
            ])),
            ("timeout".to_string(), Value::map_of([
                ("options".to_string(), Value::map_of([
                    ("active".to_string(), Value::Bool(false)),
                    ("ms".to_string(), Value::Num(30000f64)),
                ])),
                ("optspec".to_string(), Value::map_of([
                    ("clearTimer".to_string(), Value::str("`$FUNCTION`")),
                    ("setTimer".to_string(), Value::str("`$FUNCTION`")),
                ])),
                ("strict".to_string(), Value::Bool(false)),
                ("transport".to_string(), Value::str("wrap")),
            ])),
        ])),
        ("options".to_string(), Value::map_of([
            ("base".to_string(), Value::str("https://api.univec.ai")),
            ("auth".to_string(), Value::map_of([
                ("prefix".to_string(), Value::str("Bearer")),
            ])),
            ("headers".to_string(), Value::map_of([
                ("content-type".to_string(), Value::str("application/json")),
            ])),
            ("entity".to_string(), Value::map_of([
                ("convert".to_string(), Value::empty_map()),
                ("embed".to_string(), Value::empty_map()),
                ("ephemeral_key".to_string(), Value::empty_map()),
                ("model".to_string(), Value::empty_map()),
            ])),
        ])),
        ("entity".to_string(), Value::map_of([
            ("convert".to_string(), Value::map_of([
                ("fields".to_string(), Value::list(vec![
                    Value::map_of([
                        ("name".to_string(), Value::str("embeddings")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Translated vectors, in the target model's dimension.")),
                        ("type".to_string(), Value::str("`$ARRAY`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("source_model")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Model space the supplied vectors are currently in.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("target_model")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Model space to translate into.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                ])),
                ("name".to_string(), Value::str("convert")),
                ("op".to_string(), Value::map_of([
                    ("create".to_string(), Value::map_of([
                        ("input".to_string(), Value::str("data")),
                        ("name".to_string(), Value::str("create")),
                        ("points".to_string(), Value::list(vec![
                            Value::map_of([
                                ("args".to_string(), Value::empty_map()),
                                ("kind".to_string(), Value::str("http")),
                                ("method".to_string(), Value::str("POST")),
                                ("orig".to_string(), Value::str("/v1/convert")),
                                ("segments".to_string(), Value::list(vec![
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("v1")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("convert")),
                                    ]),
                                ])),
                                ("select".to_string(), Value::empty_map()),
                                ("transform".to_string(), Value::map_of([
                                    ("req".to_string(), Value::str("`reqdata`")),
                                    ("res".to_string(), Value::str("`body.data`")),
                                ])),
                                ("parts".to_string(), Value::list(vec![
                                    Value::str("v1"),
                                    Value::str("convert"),
                                ])),
                            ]),
                            Value::map_of([
                                ("args".to_string(), Value::empty_map()),
                                ("kind".to_string(), Value::str("http")),
                                ("method".to_string(), Value::str("POST")),
                                ("orig".to_string(), Value::str("/v1/embed-bridge")),
                                ("segments".to_string(), Value::list(vec![
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("v1")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("embed-bridge")),
                                    ]),
                                ])),
                                ("select".to_string(), Value::map_of([
                                    ("$action".to_string(), Value::str("bridge")),
                                ])),
                                ("transform".to_string(), Value::map_of([
                                    ("req".to_string(), Value::str("`reqdata`")),
                                    ("res".to_string(), Value::str("`body.data`")),
                                ])),
                                ("parts".to_string(), Value::list(vec![
                                    Value::str("v1"),
                                    Value::str("embed-bridge"),
                                ])),
                            ]),
                            Value::map_of([
                                ("args".to_string(), Value::empty_map()),
                                ("kind".to_string(), Value::str("http")),
                                ("method".to_string(), Value::str("POST")),
                                ("orig".to_string(), Value::str("/v1/ephemeral/convert")),
                                ("segments".to_string(), Value::list(vec![
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("v1")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("ephemeral")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("convert")),
                                    ]),
                                ])),
                                ("select".to_string(), Value::map_of([
                                    ("$action".to_string(), Value::str("ephemeral")),
                                ])),
                                ("transform".to_string(), Value::map_of([
                                    ("req".to_string(), Value::str("`reqdata`")),
                                    ("res".to_string(), Value::str("`body.data`")),
                                ])),
                                ("parts".to_string(), Value::list(vec![
                                    Value::str("v1"),
                                    Value::str("ephemeral"),
                                    Value::str("convert"),
                                ])),
                            ]),
                            Value::map_of([
                                ("args".to_string(), Value::empty_map()),
                                ("kind".to_string(), Value::str("http")),
                                ("method".to_string(), Value::str("POST")),
                                ("orig".to_string(), Value::str("/v1/ephemeral/embed-bridge")),
                                ("segments".to_string(), Value::list(vec![
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("v1")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("ephemeral")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("embed-bridge")),
                                    ]),
                                ])),
                                ("select".to_string(), Value::map_of([
                                    ("$action".to_string(), Value::str("ephemeral_bridge")),
                                ])),
                                ("transform".to_string(), Value::map_of([
                                    ("req".to_string(), Value::str("`reqdata`")),
                                    ("res".to_string(), Value::str("`body.data`")),
                                ])),
                                ("parts".to_string(), Value::list(vec![
                                    Value::str("v1"),
                                    Value::str("ephemeral"),
                                    Value::str("embed-bridge"),
                                ])),
                            ]),
                        ])),
                    ])),
                ])),
                ("relations".to_string(), Value::map_of([
                    ("ancestors".to_string(), Value::empty_list()),
                ])),
            ])),
            ("embed".to_string(), Value::map_of([
                ("fields".to_string(), Value::list(vec![
                    Value::map_of([
                        ("name".to_string(), Value::str("embeddings")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("One vector per input text, in input order.")),
                        ("type".to_string(), Value::str("`$ARRAY`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("model")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Model that produced the vectors.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("texts")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Texts to embed.")),
                        ("type".to_string(), Value::str("`$ARRAY`")),
                    ]),
                ])),
                ("name".to_string(), Value::str("embed")),
                ("op".to_string(), Value::map_of([
                    ("create".to_string(), Value::map_of([
                        ("input".to_string(), Value::str("data")),
                        ("name".to_string(), Value::str("create")),
                        ("points".to_string(), Value::list(vec![
                            Value::map_of([
                                ("args".to_string(), Value::empty_map()),
                                ("kind".to_string(), Value::str("http")),
                                ("method".to_string(), Value::str("POST")),
                                ("orig".to_string(), Value::str("/v1/embed")),
                                ("segments".to_string(), Value::list(vec![
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("v1")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("embed")),
                                    ]),
                                ])),
                                ("select".to_string(), Value::empty_map()),
                                ("transform".to_string(), Value::map_of([
                                    ("req".to_string(), Value::str("`reqdata`")),
                                    ("res".to_string(), Value::str("`body.data`")),
                                ])),
                                ("parts".to_string(), Value::list(vec![
                                    Value::str("v1"),
                                    Value::str("embed"),
                                ])),
                            ]),
                            Value::map_of([
                                ("args".to_string(), Value::empty_map()),
                                ("kind".to_string(), Value::str("http")),
                                ("method".to_string(), Value::str("POST")),
                                ("orig".to_string(), Value::str("/v1/ephemeral/embed")),
                                ("segments".to_string(), Value::list(vec![
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("v1")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("ephemeral")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("embed")),
                                    ]),
                                ])),
                                ("select".to_string(), Value::map_of([
                                    ("$action".to_string(), Value::str("ephemeral")),
                                ])),
                                ("transform".to_string(), Value::map_of([
                                    ("req".to_string(), Value::str("`reqdata`")),
                                    ("res".to_string(), Value::str("`body.data`")),
                                ])),
                                ("parts".to_string(), Value::list(vec![
                                    Value::str("v1"),
                                    Value::str("ephemeral"),
                                    Value::str("embed"),
                                ])),
                            ]),
                        ])),
                    ])),
                ])),
                ("relations".to_string(), Value::map_of([
                    ("ancestors".to_string(), Value::empty_list()),
                ])),
            ])),
            ("ephemeral_key".to_string(), Value::map_of([
                ("fields".to_string(), Value::list(vec![
                    Value::map_of([
                        ("name".to_string(), Value::str("dailyLimit")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Calls permitted per day.")),
                        ("type".to_string(), Value::str("`$INTEGER`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("dailyUsed")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Calls already used today.")),
                        ("type".to_string(), Value::str("`$INTEGER`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("key")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("The ephemeral API key, prefixed `eph_`.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                    Value::map_of([
                        ("format".to_string(), Value::str("date-time")),
                        ("name".to_string(), Value::str("resetsAt")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("When the daily allowance resets.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                ])),
                ("name".to_string(), Value::str("ephemeral_key")),
                ("op".to_string(), Value::map_of([
                    ("create".to_string(), Value::map_of([
                        ("input".to_string(), Value::str("data")),
                        ("name".to_string(), Value::str("create")),
                        ("points".to_string(), Value::list(vec![
                            Value::map_of([
                                ("args".to_string(), Value::empty_map()),
                                ("kind".to_string(), Value::str("http")),
                                ("method".to_string(), Value::str("POST")),
                                ("orig".to_string(), Value::str("/v1/ephemeral/key")),
                                ("segments".to_string(), Value::list(vec![
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("v1")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("ephemeral")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("key")),
                                    ]),
                                ])),
                                ("select".to_string(), Value::empty_map()),
                                ("transform".to_string(), Value::map_of([
                                    ("req".to_string(), Value::str("`reqdata`")),
                                    ("res".to_string(), Value::str("`body.data`")),
                                ])),
                                ("parts".to_string(), Value::list(vec![
                                    Value::str("v1"),
                                    Value::str("ephemeral"),
                                    Value::str("key"),
                                ])),
                            ]),
                        ])),
                    ])),
                ])),
                ("relations".to_string(), Value::map_of([
                    ("ancestors".to_string(), Value::empty_list()),
                ])),
            ])),
            ("model".to_string(), Value::map_of([
                ("fields".to_string(), Value::list(vec![
                    Value::map_of([
                        ("name".to_string(), Value::str("eval")),
                        ("short".to_string(), Value::str("Retrieval-fidelity metrics for a convert model.")),
                        ("type".to_string(), Value::str("`$OBJECT`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("executionProvider")),
                        ("short".to_string(), Value::str("Hardware backend, e.g.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("modelCard")),
                        ("short".to_string(), Value::str("Convert models only: training provenance and architecture detail.")),
                        ("type".to_string(), Value::str("`$OBJECT`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("modelType")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("`embed` for text-to-vector models, `convert` for space-translation models.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("name")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Model identifier used in requests.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("sequenceLen")),
                        ("short".to_string(), Value::str("Embed models only: maximum input sequence length.")),
                        ("type".to_string(), Value::str("`$INTEGER`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("sourceDim")),
                        ("short".to_string(), Value::str("Convert models only: source vector dimension.")),
                        ("type".to_string(), Value::str("`$INTEGER`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("sourceModel")),
                        ("short".to_string(), Value::str("Convert models only: the source model space.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("targetDim")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("Dimension of the produced vectors.")),
                        ("type".to_string(), Value::str("`$INTEGER`")),
                    ]),
                    Value::map_of([
                        ("name".to_string(), Value::str("targetModel")),
                        ("req".to_string(), Value::Bool(true)),
                        ("short".to_string(), Value::str("The model space produced.")),
                        ("type".to_string(), Value::str("`$STRING`")),
                    ]),
                ])),
                ("name".to_string(), Value::str("model")),
                ("op".to_string(), Value::map_of([
                    ("list".to_string(), Value::map_of([
                        ("input".to_string(), Value::str("data")),
                        ("name".to_string(), Value::str("list")),
                        ("points".to_string(), Value::list(vec![
                            Value::map_of([
                                ("args".to_string(), Value::empty_map()),
                                ("kind".to_string(), Value::str("http")),
                                ("method".to_string(), Value::str("GET")),
                                ("orig".to_string(), Value::str("/v1/models")),
                                ("segments".to_string(), Value::list(vec![
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("v1")),
                                    ]),
                                    Value::map_of([
                                        ("lit".to_string(), Value::str("models")),
                                    ]),
                                ])),
                                ("select".to_string(), Value::empty_map()),
                                ("transform".to_string(), Value::map_of([
                                    ("req".to_string(), Value::str("`reqdata`")),
                                    ("res".to_string(), Value::str("`body.data`")),
                                ])),
                                ("parts".to_string(), Value::list(vec![
                                    Value::str("v1"),
                                    Value::str("models"),
                                ])),
                            ]),
                        ])),
                    ])),
                ])),
                ("relations".to_string(), Value::map_of([
                    ("ancestors".to_string(), Value::empty_list()),
                ])),
            ])),
        ])),
    ])
}

// SHARED CONFIG (sdkgen rung L2).
//
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client. Above the
// size threshold make_config re-parses the whole embedded JSON, so this is the
// difference between parsing the model once and once per client.
//
// THREAD-LOCAL, not a global: Value is Rc/RefCell-backed and so is neither
// Send nor Sync. One config per thread is the widest scope that is sound here,
// and the clone is an Rc bump, not a deep copy.
thread_local! {
    static SHARED_CONFIG: Value = make_config();
}

/// The per-thread config, built once on first use.
///
/// The returned Value SHARES its nodes: treat it as read-only. Callers that
/// need to mutate should use make_config, which always returns a fresh copy.
pub fn shared_config() -> Value {
    SHARED_CONFIG.with(|c| c.clone())
}

pub fn make_feature(name: &str) -> FeatureRef {
    match name {
        "audit" => Rc::new(RefCell::new(crate::feature::audit::AuditFeature::new())),
        "cache" => Rc::new(RefCell::new(crate::feature::cache::CacheFeature::new())),
        "clienttrack" => Rc::new(RefCell::new(crate::feature::clienttrack::ClienttrackFeature::new())),
        "cost" => Rc::new(RefCell::new(crate::feature::cost::CostFeature::new())),
        "debug" => Rc::new(RefCell::new(crate::feature::debug::DebugFeature::new())),
        "idempotency" => Rc::new(RefCell::new(crate::feature::idempotency::IdempotencyFeature::new())),
        "log" => Rc::new(RefCell::new(crate::feature::log::LogFeature::new())),
        "metrics" => Rc::new(RefCell::new(crate::feature::metrics::MetricsFeature::new())),
        "netsim" => Rc::new(RefCell::new(crate::feature::netsim::NetsimFeature::new())),
        "paging" => Rc::new(RefCell::new(crate::feature::paging::PagingFeature::new())),
        "proxy" => Rc::new(RefCell::new(crate::feature::proxy::ProxyFeature::new())),
        "ratelimit" => Rc::new(RefCell::new(crate::feature::ratelimit::RatelimitFeature::new())),
        "rbac" => Rc::new(RefCell::new(crate::feature::rbac::RbacFeature::new())),
        "retry" => Rc::new(RefCell::new(crate::feature::retry::RetryFeature::new())),
        "secrets" => Rc::new(RefCell::new(crate::feature::secrets::SecretsFeature::new())),
        "streaming" => Rc::new(RefCell::new(crate::feature::streaming::StreamingFeature::new())),
        "telemetry" => Rc::new(RefCell::new(crate::feature::telemetry::TelemetryFeature::new())),
        "test" => Rc::new(RefCell::new(crate::feature::test::TestFeature::new())),
        "timeout" => Rc::new(RefCell::new(crate::feature::timeout::TimeoutFeature::new())),
        _ => Rc::new(RefCell::new(crate::feature::base::BaseFeature::new())),
    }
}
