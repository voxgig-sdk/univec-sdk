"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.FEATURE_PLUGINS = exports.config = void 0;
const AuditFeature_1 = require("./feature/audit/AuditFeature");
const CacheFeature_1 = require("./feature/cache/CacheFeature");
const ClienttrackFeature_1 = require("./feature/clienttrack/ClienttrackFeature");
const CostFeature_1 = require("./feature/cost/CostFeature");
const DebugFeature_1 = require("./feature/debug/DebugFeature");
const IdempotencyFeature_1 = require("./feature/idempotency/IdempotencyFeature");
const LogFeature_1 = require("./feature/log/LogFeature");
const MetricsFeature_1 = require("./feature/metrics/MetricsFeature");
const NetsimFeature_1 = require("./feature/netsim/NetsimFeature");
const PagingFeature_1 = require("./feature/paging/PagingFeature");
const ProxyFeature_1 = require("./feature/proxy/ProxyFeature");
const RatelimitFeature_1 = require("./feature/ratelimit/RatelimitFeature");
const RbacFeature_1 = require("./feature/rbac/RbacFeature");
const RetryFeature_1 = require("./feature/retry/RetryFeature");
const SecretsFeature_1 = require("./feature/secrets/SecretsFeature");
const StreamingFeature_1 = require("./feature/streaming/StreamingFeature");
const TelemetryFeature_1 = require("./feature/telemetry/TelemetryFeature");
const TestFeature_1 = require("./feature/test/TestFeature");
const TimeoutFeature_1 = require("./feature/timeout/TimeoutFeature");
const boru_1 = require("./feature/secrets/sekreto/plugins/boru");
const hashicorp_1 = require("./feature/secrets/sekreto/plugins/hashicorp");
const FEATURE_CLASS = {
    audit: AuditFeature_1.AuditFeature,
    cache: CacheFeature_1.CacheFeature,
    clienttrack: ClienttrackFeature_1.ClienttrackFeature,
    cost: CostFeature_1.CostFeature,
    debug: DebugFeature_1.DebugFeature,
    idempotency: IdempotencyFeature_1.IdempotencyFeature,
    log: LogFeature_1.LogFeature,
    metrics: MetricsFeature_1.MetricsFeature,
    netsim: NetsimFeature_1.NetsimFeature,
    paging: PagingFeature_1.PagingFeature,
    proxy: ProxyFeature_1.ProxyFeature,
    ratelimit: RatelimitFeature_1.RatelimitFeature,
    rbac: RbacFeature_1.RbacFeature,
    retry: RetryFeature_1.RetryFeature,
    secrets: SecretsFeature_1.SecretsFeature,
    streaming: StreamingFeature_1.StreamingFeature,
    telemetry: TelemetryFeature_1.TelemetryFeature,
    test: TestFeature_1.TestFeature,
    timeout: TimeoutFeature_1.TimeoutFeature,
};
// Per-feature plugin DEFINITIONS (voxgig/plugin `Definition` values), from
// the model's active plugin groups. A feature that takes a `plugins` option
// (secrets over sekreto) reads its own entry; a feature with no plugins has
// none. Named imports above make each definition statically reachable, so
// an SDK carries exactly the plugin modules its model selects — the same
// leanness the old side-effect registry imports bought, without a registry.
const FEATURE_PLUGINS = {
    secrets: [boru_1.boru, hashicorp_1.hashicorp],
};
exports.FEATURE_PLUGINS = FEATURE_PLUGINS;
class Config {
    makeFeature(fn) {
        const fc = FEATURE_CLASS[fn];
        const fi = new fc();
        // TODO: errors etc
        return fi;
    }
    // False for a feature added at runtime via options.extend (station's
    // adopt path) - the constructor uses this to skip makeFeature for names
    // no generated class backs.
    hasFeature(fn) {
        return null != FEATURE_CLASS[fn];
    }
    main = {
        name: 'Univec',
        slug: "univec",
        version: "0.1.2",
        target: "ts",
    };
    feature = {
        audit: {
            "options": {
                "active": false,
                "actor": "anonymous",
                "max": 1000
            },
            "transport": "none"
        },
        cache: {
            "options": {
                "active": false,
                "max": 256,
                "methods": [
                    "GET"
                ],
                "ttl": 5000
            },
            "transport": "wrap"
        },
        clienttrack: {
            "options": {
                "active": false,
                "clientVersion": "0.0.1"
            },
            "transport": "none"
        },
        cost: {
            "options": {
                "active": false,
                "budget": 0,
                "currency": "USD",
                "header": "",
                "onBudget": "warn",
                "path": "",
                "perUnit": 0,
                "rates": {},
                "unit": 0
            },
            "transport": "wrap"
        },
        debug: {
            "options": {
                "active": false,
                "max": 100,
                "redact": [
                    "authorization",
                    "cookie",
                    "set-cookie",
                    "api-key",
                    "apikey",
                    "x-api-key",
                    "idempotency-key"
                ]
            },
            "transport": "none"
        },
        idempotency: {
            "options": {
                "active": false,
                "header": "Idempotency-Key",
                "methods": [
                    "POST",
                    "PUT",
                    "PATCH",
                    "DELETE"
                ],
                "ops": [
                    "create",
                    "update",
                    "remove"
                ]
            },
            "transport": "none"
        },
        log: {
            "options": {
                "active": true
            },
            "transport": "none"
        },
        metrics: {
            "options": {
                "active": false
            },
            "transport": "none"
        },
        netsim: {
            "options": {
                "active": false,
                "errorTimes": 0,
                "failEvery": 0,
                "failRate": 0,
                "failStatus": 503,
                "failTimes": 0,
                "latency": 0,
                "offline": false,
                "rateLimitTimes": 0,
                "retryAfter": 0,
                "seed": 1
            },
            "transport": "wrap"
        },
        paging: {
            "options": {
                "active": false,
                "afterVar": "after",
                "cursorParam": "cursor",
                "firstVar": "first",
                "limitParam": "limit",
                "pageParam": "page",
                "startPage": 1
            },
            "transport": "none"
        },
        proxy: {
            "options": {
                "active": false,
                "fromEnv": false,
                "noProxy": [],
                "url": ""
            },
            "transport": "wrap"
        },
        ratelimit: {
            "options": {
                "active": false,
                "burst": 5,
                "rate": 5
            },
            "transport": "wrap"
        },
        rbac: {
            "options": {
                "active": false,
                "deny": false,
                "permissions": [],
                "rules": {}
            },
            "transport": "none"
        },
        retry: {
            "options": {
                "active": false,
                "factor": 2,
                "maxDelay": 2000,
                "minDelay": 50,
                "retries": 2,
                "statuses": [
                    408,
                    425,
                    429,
                    500,
                    502,
                    503,
                    504
                ]
            },
            "transport": "wrap"
        },
        secrets: {
            "options": {
                "active": false,
                "cache": true,
                "exchange": {
                    "active": false,
                    "method": "POST",
                    "path": "auth/token",
                    "refresh": "",
                    "request": "refresh_token",
                    "response": "access_token",
                    "retries": 1,
                    "statuses": [
                        401
                    ]
                },
                "name": "univec",
                "providers": [
                    {
                        "kind": "boru",
                        "namespace": "sdk"
                    }
                ]
            },
            "transport": "wrap"
        },
        streaming: {
            "options": {
                "active": false,
                "chunkDelay": 0,
                "chunkSize": 0
            },
            "transport": "none"
        },
        telemetry: {
            "options": {
                "active": false
            },
            "transport": "none"
        },
        test: {
            "options": {
                "active": false
            },
            "transport": "base"
        },
        timeout: {
            "options": {
                "active": false,
                "ms": 30000
            },
            "transport": "wrap"
        },
    };
    options = {
        base: "https://api.univec.ai",
        auth: {
            prefix: 'Bearer',
        },
        headers: {
            "content-type": "application/json"
        },
        entity: {
            convert: {},
            embed: {},
            ephemeral_key: {},
            model: {},
        }
    };
    entity = {
        "convert": {
            "fields": [
                {
                    "name": "bridge_model",
                    "req": true,
                    "short": "Embed model used to vectorise the text before translation.",
                    "type": "`$STRING`"
                },
                {
                    "name": "embeddings",
                    "req": true,
                    "short": "Translated vectors, in the target model's dimension.",
                    "type": "`$ARRAY`"
                },
                {
                    "name": "source_model",
                    "req": true,
                    "short": "Model space the supplied vectors are currently in.",
                    "type": "`$STRING`"
                },
                {
                    "name": "target_model",
                    "req": true,
                    "short": "Model space to translate into.",
                    "type": "`$STRING`"
                },
                {
                    "name": "texts",
                    "req": true,
                    "short": "Texts to embed and translate.",
                    "type": "`$ARRAY`"
                }
            ],
            "name": "convert",
            "op": {
                "create": {
                    "input": "data",
                    "name": "create",
                    "points": [
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/convert",
                            "segments": [
                                {
                                    "lit": "v1"
                                },
                                {
                                    "lit": "convert"
                                }
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            },
                            "parts": [
                                "v1",
                                "convert"
                            ]
                        },
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/embed-bridge",
                            "segments": [
                                {
                                    "lit": "v1"
                                },
                                {
                                    "lit": "embed-bridge"
                                }
                            ],
                            "select": {
                                "$action": "bridge"
                            },
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            },
                            "parts": [
                                "v1",
                                "embed-bridge"
                            ]
                        },
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/ephemeral/convert",
                            "segments": [
                                {
                                    "lit": "v1"
                                },
                                {
                                    "lit": "ephemeral"
                                },
                                {
                                    "lit": "convert"
                                }
                            ],
                            "select": {
                                "$action": "ephemeral"
                            },
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            },
                            "parts": [
                                "v1",
                                "ephemeral",
                                "convert"
                            ]
                        },
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/ephemeral/embed-bridge",
                            "segments": [
                                {
                                    "lit": "v1"
                                },
                                {
                                    "lit": "ephemeral"
                                },
                                {
                                    "lit": "embed-bridge"
                                }
                            ],
                            "select": {
                                "$action": "ephemeral_bridge"
                            },
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            },
                            "parts": [
                                "v1",
                                "ephemeral",
                                "embed-bridge"
                            ]
                        }
                    ]
                }
            },
            "relations": {
                "ancestors": []
            }
        },
        "embed": {
            "fields": [
                {
                    "name": "embeddings",
                    "req": true,
                    "short": "One vector per input text, in input order.",
                    "type": "`$ARRAY`"
                },
                {
                    "name": "model",
                    "req": true,
                    "short": "Model that produced the vectors.",
                    "type": "`$STRING`"
                },
                {
                    "name": "texts",
                    "req": true,
                    "short": "Texts to embed.",
                    "type": "`$ARRAY`"
                }
            ],
            "name": "embed",
            "op": {
                "create": {
                    "input": "data",
                    "name": "create",
                    "points": [
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/embed",
                            "segments": [
                                {
                                    "lit": "v1"
                                },
                                {
                                    "lit": "embed"
                                }
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            },
                            "parts": [
                                "v1",
                                "embed"
                            ]
                        },
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/ephemeral/embed",
                            "segments": [
                                {
                                    "lit": "v1"
                                },
                                {
                                    "lit": "ephemeral"
                                },
                                {
                                    "lit": "embed"
                                }
                            ],
                            "select": {
                                "$action": "ephemeral"
                            },
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            },
                            "parts": [
                                "v1",
                                "ephemeral",
                                "embed"
                            ]
                        }
                    ]
                }
            },
            "relations": {
                "ancestors": []
            }
        },
        "ephemeral_key": {
            "fields": [
                {
                    "name": "dailyLimit",
                    "req": true,
                    "short": "Calls permitted per day.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "dailyUsed",
                    "req": true,
                    "short": "Calls already used today.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "key",
                    "req": true,
                    "short": "The ephemeral API key, prefixed `eph_`.",
                    "type": "`$STRING`"
                },
                {
                    "format": "date-time",
                    "name": "resetsAt",
                    "req": true,
                    "short": "When the daily allowance resets.",
                    "type": "`$STRING`"
                }
            ],
            "name": "ephemeral_key",
            "op": {
                "create": {
                    "input": "data",
                    "name": "create",
                    "points": [
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/ephemeral/key",
                            "segments": [
                                {
                                    "lit": "v1"
                                },
                                {
                                    "lit": "ephemeral"
                                },
                                {
                                    "lit": "key"
                                }
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            },
                            "parts": [
                                "v1",
                                "ephemeral",
                                "key"
                            ]
                        }
                    ]
                }
            },
            "relations": {
                "ancestors": []
            }
        },
        "model": {
            "fields": [
                {
                    "name": "eval",
                    "short": "Retrieval-fidelity metrics for a convert model.",
                    "type": "`$OBJECT`"
                },
                {
                    "name": "executionProvider",
                    "short": "Hardware backend, e.g.",
                    "type": "`$STRING`"
                },
                {
                    "name": "modelCard",
                    "short": "Convert models only: training provenance and architecture detail.",
                    "type": "`$OBJECT`"
                },
                {
                    "name": "modelType",
                    "req": true,
                    "short": "`embed` for text-to-vector models, `convert` for space-translation models.",
                    "type": "`$STRING`"
                },
                {
                    "name": "name",
                    "req": true,
                    "short": "Model identifier used in requests.",
                    "type": "`$STRING`"
                },
                {
                    "name": "sequenceLen",
                    "short": "Embed models only: maximum input sequence length.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "sourceDim",
                    "short": "Convert models only: source vector dimension.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "sourceModel",
                    "short": "Convert models only: the source model space.",
                    "type": "`$STRING`"
                },
                {
                    "name": "targetDim",
                    "req": true,
                    "short": "Dimension of the produced vectors.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "targetModel",
                    "req": true,
                    "short": "The model space produced.",
                    "type": "`$STRING`"
                }
            ],
            "name": "model",
            "op": {
                "list": {
                    "input": "data",
                    "name": "list",
                    "points": [
                        {
                            "args": {},
                            "kind": "http",
                            "method": "GET",
                            "orig": "/v1/models",
                            "segments": [
                                {
                                    "lit": "v1"
                                },
                                {
                                    "lit": "models"
                                }
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            },
                            "parts": [
                                "v1",
                                "models"
                            ]
                        }
                    ]
                }
            },
            "relations": {
                "ancestors": []
            }
        }
    };
}
const config = new Config();
exports.config = config;
//# sourceMappingURL=Config.js.map