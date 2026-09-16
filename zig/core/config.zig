// Generated API configuration (mirrors go/rust core/config).

const std = @import("std");
const h = @import("helpers.zig");
const types = @import("types.zig");
const Value = h.Value;
const Feature = types.Feature;

pub fn make_config() Value {
    return h.jo(&.{
        .{ "main", h.jo(&.{
            .{ "name", h.vstr("Univec") },
            .{ "slug", h.vstr("univec") },
            .{ "version", h.vstr("0.1.2") },
            .{ "target", h.vstr("zig") },
        }) },
        .{ "feature", h.jo(&.{
            .{ "audit", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "actor", h.vstr("anonymous") },
                    .{ "max", h.vnum(1000) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "cache", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "max", h.vnum(256) },
                    .{ "methods", h.ja(&.{
                        h.vstr("GET"),
                    }) },
                    .{ "ttl", h.vnum(5000) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("wrap") },
            }) },
            .{ "clienttrack", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "clientVersion", h.vstr("0.0.1") },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "cost", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "budget", h.vnum(0) },
                    .{ "currency", h.vstr("USD") },
                    .{ "header", h.vstr("") },
                    .{ "onBudget", h.vstr("warn") },
                    .{ "path", h.vstr("") },
                    .{ "perUnit", h.vnum(0) },
                    .{ "rates", h.omap() },
                    .{ "unit", h.vnum(0) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("wrap") },
            }) },
            .{ "debug", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "max", h.vnum(100) },
                    .{ "redact", h.ja(&.{
                        h.vstr("authorization"),
                        h.vstr("cookie"),
                        h.vstr("set-cookie"),
                        h.vstr("api-key"),
                        h.vstr("apikey"),
                        h.vstr("x-api-key"),
                        h.vstr("idempotency-key"),
                    }) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "idempotency", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "header", h.vstr("Idempotency-Key") },
                    .{ "methods", h.ja(&.{
                        h.vstr("POST"),
                        h.vstr("PUT"),
                        h.vstr("PATCH"),
                        h.vstr("DELETE"),
                    }) },
                    .{ "ops", h.ja(&.{
                        h.vstr("create"),
                        h.vstr("update"),
                        h.vstr("remove"),
                    }) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "log", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(true) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "metrics", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "netsim", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "errorTimes", h.vnum(0) },
                    .{ "failEvery", h.vnum(0) },
                    .{ "failRate", h.vnum(0) },
                    .{ "failStatus", h.vnum(503) },
                    .{ "failTimes", h.vnum(0) },
                    .{ "latency", h.vnum(0) },
                    .{ "offline", h.vbool(false) },
                    .{ "rateLimitTimes", h.vnum(0) },
                    .{ "retryAfter", h.vnum(0) },
                    .{ "seed", h.vnum(1) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("wrap") },
            }) },
            .{ "paging", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "afterVar", h.vstr("after") },
                    .{ "cursorParam", h.vstr("cursor") },
                    .{ "firstVar", h.vstr("first") },
                    .{ "limitParam", h.vstr("limit") },
                    .{ "pageParam", h.vstr("page") },
                    .{ "startPage", h.vnum(1) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "proxy", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "fromEnv", h.vbool(false) },
                    .{ "noProxy", h.olist() },
                    .{ "url", h.vstr("") },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("wrap") },
            }) },
            .{ "ratelimit", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "burst", h.vnum(5) },
                    .{ "rate", h.vnum(5) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("wrap") },
            }) },
            .{ "rbac", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "deny", h.vbool(false) },
                    .{ "permissions", h.olist() },
                    .{ "rules", h.omap() },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "retry", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "factor", h.vnum(2) },
                    .{ "maxDelay", h.vnum(2000) },
                    .{ "minDelay", h.vnum(50) },
                    .{ "retries", h.vnum(2) },
                    .{ "statuses", h.ja(&.{
                        h.vnum(408),
                        h.vnum(425),
                        h.vnum(429),
                        h.vnum(500),
                        h.vnum(502),
                        h.vnum(503),
                        h.vnum(504),
                    }) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("wrap") },
            }) },
            .{ "secrets", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "cache", h.vbool(true) },
                    .{ "exchange", h.jo(&.{
                        .{ "active", h.vbool(false) },
                        .{ "method", h.vstr("POST") },
                        .{ "path", h.vstr("auth/token") },
                        .{ "refresh", h.vstr("") },
                        .{ "request", h.vstr("refresh_token") },
                        .{ "response", h.vstr("access_token") },
                        .{ "retries", h.vnum(1) },
                        .{ "statuses", h.ja(&.{
                            h.vnum(401),
                        }) },
                    }) },
                    .{ "name", h.vstr("univec") },
                    .{ "providers", h.ja(&.{
                        h.jo(&.{
                            .{ "kind", h.vstr("boru") },
                            .{ "namespace", h.vstr("sdk") },
                        }),
                    }) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("wrap") },
            }) },
            .{ "streaming", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "chunkDelay", h.vnum(0) },
                    .{ "chunkSize", h.vnum(0) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "telemetry", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("none") },
            }) },
            .{ "test", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("base") },
            }) },
            .{ "timeout", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                    .{ "ms", h.vnum(30000) },
                }) },
                .{ "optspec", h.omap() },
                .{ "strict", h.vbool(false) },
                .{ "transport", h.vstr("wrap") },
            }) },
        }) },
        .{ "options", h.jo(&.{
            .{ "base", h.vstr("https://api.univec.ai") },
            .{ "auth", h.jo(&.{
                .{ "prefix", h.vstr("Bearer") },
            }) },
            .{ "headers", h.jo(&.{
                .{ "content-type", h.vstr("application/json") },
            }) },
            .{ "entity", h.jo(&.{
                .{ "convert", h.omap() },
                .{ "embed", h.omap() },
                .{ "ephemeral_key", h.omap() },
                .{ "model", h.omap() },
            }) },
        }) },
        .{ "entity", h.jo(&.{
            .{ "convert", h.jo(&.{
                .{ "fields", h.ja(&.{
                    h.jo(&.{
                        .{ "name", h.vstr("bridge_model") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Embed model used to vectorise the text before translation.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("embeddings") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Translated vectors, in the target model's dimension.") },
                        .{ "type", h.vstr("`$ARRAY`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("source_model") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Model space the supplied vectors are currently in.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("target_model") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Model space to translate into.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("texts") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Texts to embed and translate.") },
                        .{ "type", h.vstr("`$ARRAY`") },
                    }),
                }) },
                .{ "name", h.vstr("convert") },
                .{ "op", h.jo(&.{
                    .{ "create", h.jo(&.{
                        .{ "input", h.vstr("data") },
                        .{ "name", h.vstr("create") },
                        .{ "points", h.ja(&.{
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/convert") },
                                .{ "segments", h.ja(&.{
                                    h.jo(&.{
                                        .{ "lit", h.vstr("v1") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("convert") },
                                    }),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("convert"),
                                }) },
                            }),
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/embed-bridge") },
                                .{ "segments", h.ja(&.{
                                    h.jo(&.{
                                        .{ "lit", h.vstr("v1") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("embed-bridge") },
                                    }),
                                }) },
                                .{ "select", h.jo(&.{
                                    .{ "$action", h.vstr("bridge") },
                                }) },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("embed-bridge"),
                                }) },
                            }),
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/ephemeral/convert") },
                                .{ "segments", h.ja(&.{
                                    h.jo(&.{
                                        .{ "lit", h.vstr("v1") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("ephemeral") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("convert") },
                                    }),
                                }) },
                                .{ "select", h.jo(&.{
                                    .{ "$action", h.vstr("ephemeral") },
                                }) },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("ephemeral"),
                                    h.vstr("convert"),
                                }) },
                            }),
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/ephemeral/embed-bridge") },
                                .{ "segments", h.ja(&.{
                                    h.jo(&.{
                                        .{ "lit", h.vstr("v1") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("ephemeral") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("embed-bridge") },
                                    }),
                                }) },
                                .{ "select", h.jo(&.{
                                    .{ "$action", h.vstr("ephemeral_bridge") },
                                }) },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("ephemeral"),
                                    h.vstr("embed-bridge"),
                                }) },
                            }),
                        }) },
                    }) },
                }) },
                .{ "relations", h.jo(&.{
                    .{ "ancestors", h.olist() },
                }) },
            }) },
            .{ "embed", h.jo(&.{
                .{ "fields", h.ja(&.{
                    h.jo(&.{
                        .{ "name", h.vstr("embeddings") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("One vector per input text, in input order.") },
                        .{ "type", h.vstr("`$ARRAY`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("model") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Model that produced the vectors.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("texts") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Texts to embed.") },
                        .{ "type", h.vstr("`$ARRAY`") },
                    }),
                }) },
                .{ "name", h.vstr("embed") },
                .{ "op", h.jo(&.{
                    .{ "create", h.jo(&.{
                        .{ "input", h.vstr("data") },
                        .{ "name", h.vstr("create") },
                        .{ "points", h.ja(&.{
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/embed") },
                                .{ "segments", h.ja(&.{
                                    h.jo(&.{
                                        .{ "lit", h.vstr("v1") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("embed") },
                                    }),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("embed"),
                                }) },
                            }),
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/ephemeral/embed") },
                                .{ "segments", h.ja(&.{
                                    h.jo(&.{
                                        .{ "lit", h.vstr("v1") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("ephemeral") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("embed") },
                                    }),
                                }) },
                                .{ "select", h.jo(&.{
                                    .{ "$action", h.vstr("ephemeral") },
                                }) },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("ephemeral"),
                                    h.vstr("embed"),
                                }) },
                            }),
                        }) },
                    }) },
                }) },
                .{ "relations", h.jo(&.{
                    .{ "ancestors", h.olist() },
                }) },
            }) },
            .{ "ephemeral_key", h.jo(&.{
                .{ "fields", h.ja(&.{
                    h.jo(&.{
                        .{ "name", h.vstr("dailyLimit") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Calls permitted per day.") },
                        .{ "type", h.vstr("`$INTEGER`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("dailyUsed") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Calls already used today.") },
                        .{ "type", h.vstr("`$INTEGER`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("key") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("The ephemeral API key, prefixed `eph_`.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "format", h.vstr("date-time") },
                        .{ "name", h.vstr("resetsAt") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("When the daily allowance resets.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                }) },
                .{ "name", h.vstr("ephemeral_key") },
                .{ "op", h.jo(&.{
                    .{ "create", h.jo(&.{
                        .{ "input", h.vstr("data") },
                        .{ "name", h.vstr("create") },
                        .{ "points", h.ja(&.{
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/ephemeral/key") },
                                .{ "segments", h.ja(&.{
                                    h.jo(&.{
                                        .{ "lit", h.vstr("v1") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("ephemeral") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("key") },
                                    }),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("ephemeral"),
                                    h.vstr("key"),
                                }) },
                            }),
                        }) },
                    }) },
                }) },
                .{ "relations", h.jo(&.{
                    .{ "ancestors", h.olist() },
                }) },
            }) },
            .{ "model", h.jo(&.{
                .{ "fields", h.ja(&.{
                    h.jo(&.{
                        .{ "name", h.vstr("eval") },
                        .{ "short", h.vstr("Retrieval-fidelity metrics for a convert model.") },
                        .{ "type", h.vstr("`$OBJECT`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("executionProvider") },
                        .{ "short", h.vstr("Hardware backend, e.g.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("modelCard") },
                        .{ "short", h.vstr("Convert models only: training provenance and architecture detail.") },
                        .{ "type", h.vstr("`$OBJECT`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("modelType") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("`embed` for text-to-vector models, `convert` for space-translation models.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("name") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Model identifier used in requests.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("sequenceLen") },
                        .{ "short", h.vstr("Embed models only: maximum input sequence length.") },
                        .{ "type", h.vstr("`$INTEGER`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("sourceDim") },
                        .{ "short", h.vstr("Convert models only: source vector dimension.") },
                        .{ "type", h.vstr("`$INTEGER`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("sourceModel") },
                        .{ "short", h.vstr("Convert models only: the source model space.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("targetDim") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("Dimension of the produced vectors.") },
                        .{ "type", h.vstr("`$INTEGER`") },
                    }),
                    h.jo(&.{
                        .{ "name", h.vstr("targetModel") },
                        .{ "req", h.vbool(true) },
                        .{ "short", h.vstr("The model space produced.") },
                        .{ "type", h.vstr("`$STRING`") },
                    }),
                }) },
                .{ "name", h.vstr("model") },
                .{ "op", h.jo(&.{
                    .{ "list", h.jo(&.{
                        .{ "input", h.vstr("data") },
                        .{ "name", h.vstr("list") },
                        .{ "points", h.ja(&.{
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("GET") },
                                .{ "orig", h.vstr("/v1/models") },
                                .{ "segments", h.ja(&.{
                                    h.jo(&.{
                                        .{ "lit", h.vstr("v1") },
                                    }),
                                    h.jo(&.{
                                        .{ "lit", h.vstr("models") },
                                    }),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("models"),
                                }) },
                            }),
                        }) },
                    }) },
                }) },
                .{ "relations", h.jo(&.{
                    .{ "ancestors", h.olist() },
                }) },
            }) },
        }) },
    });
}

// SHARED CONFIG (sdkgen rung L2).
//
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client. Above the
// size threshold make_config re-parses the whole embedded JSON, so this is the
// difference between parsing the model once and once per client.
//
// Value nodes are arena-allocated and reference-stable, so the shared value is
// genuinely one structure, not a copy.
var shared_config_val: ?Value = null;

/// The process-wide config, built once on first use.
///
/// The returned Value SHARES its nodes: treat it as read-only. Callers that
/// need to mutate should use make_config, which always returns a fresh copy.
pub fn shared_config() Value {
    if (shared_config_val) |c| return c;
    const c = make_config();
    shared_config_val = c;
    return c;
}

pub fn make_feature(name: []const u8) Feature {
    if (std.mem.eql(u8, name, "audit")) return @import("../feature/audit.zig").AuditFeature.make();
    if (std.mem.eql(u8, name, "cache")) return @import("../feature/cache.zig").CacheFeature.make();
    if (std.mem.eql(u8, name, "clienttrack")) return @import("../feature/clienttrack.zig").ClienttrackFeature.make();
    if (std.mem.eql(u8, name, "cost")) return @import("../feature/cost.zig").CostFeature.make();
    if (std.mem.eql(u8, name, "debug")) return @import("../feature/debug.zig").DebugFeature.make();
    if (std.mem.eql(u8, name, "idempotency")) return @import("../feature/idempotency.zig").IdempotencyFeature.make();
    if (std.mem.eql(u8, name, "log")) return @import("../feature/log.zig").LogFeature.make();
    if (std.mem.eql(u8, name, "metrics")) return @import("../feature/metrics.zig").MetricsFeature.make();
    if (std.mem.eql(u8, name, "netsim")) return @import("../feature/netsim.zig").NetsimFeature.make();
    if (std.mem.eql(u8, name, "paging")) return @import("../feature/paging.zig").PagingFeature.make();
    if (std.mem.eql(u8, name, "proxy")) return @import("../feature/proxy.zig").ProxyFeature.make();
    if (std.mem.eql(u8, name, "ratelimit")) return @import("../feature/ratelimit.zig").RatelimitFeature.make();
    if (std.mem.eql(u8, name, "rbac")) return @import("../feature/rbac.zig").RbacFeature.make();
    if (std.mem.eql(u8, name, "retry")) return @import("../feature/retry.zig").RetryFeature.make();
    if (std.mem.eql(u8, name, "streaming")) return @import("../feature/streaming.zig").StreamingFeature.make();
    if (std.mem.eql(u8, name, "telemetry")) return @import("../feature/telemetry.zig").TelemetryFeature.make();
    if (std.mem.eql(u8, name, "test")) return @import("../feature/test.zig").TestFeature.make();
    if (std.mem.eql(u8, name, "timeout")) return @import("../feature/timeout.zig").TimeoutFeature.make();
    if (std.mem.eql(u8, name, "secrets")) return @import("../feature/secrets.zig").SecretsFeature.make();
    return @import("../feature/base.zig").BaseFeature.make();
}
