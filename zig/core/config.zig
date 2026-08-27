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
            .{ "version", h.vstr("0.1.1") },
            .{ "target", h.vstr("zig") },
        }) },
        .{ "feature", h.jo(&.{
            .{ "test", h.jo(&.{
                .{ "options", h.jo(&.{
                    .{ "active", h.vbool(false) },
                }) },
                .{ "transport", h.vstr("base") },
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
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("convert"),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                            }),
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/embed-bridge") },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("embed-bridge"),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                            }),
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/ephemeral/convert") },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("ephemeral"),
                                    h.vstr("convert"),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                            }),
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/ephemeral/embed-bridge") },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("ephemeral"),
                                    h.vstr("embed-bridge"),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
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
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("embed"),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
                                }) },
                            }),
                            h.jo(&.{
                                .{ "args", h.omap() },
                                .{ "kind", h.vstr("http") },
                                .{ "method", h.vstr("POST") },
                                .{ "orig", h.vstr("/v1/ephemeral/embed") },
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("ephemeral"),
                                    h.vstr("embed"),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
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
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("ephemeral"),
                                    h.vstr("key"),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
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
                                .{ "parts", h.ja(&.{
                                    h.vstr("v1"),
                                    h.vstr("models"),
                                }) },
                                .{ "select", h.omap() },
                                .{ "transform", h.jo(&.{
                                    .{ "req", h.vstr("`reqdata`") },
                                    .{ "res", h.vstr("`body.data`") },
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
    return @import("../feature/base.zig").BaseFeature.make();
}
