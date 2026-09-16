
const { BaseFeature } = require('./feature/base/BaseFeature')
const { AuditFeature } = require('./feature/audit/AuditFeature')
const { CacheFeature } = require('./feature/cache/CacheFeature')
const { ClienttrackFeature } = require('./feature/clienttrack/ClienttrackFeature')
const { CostFeature } = require('./feature/cost/CostFeature')
const { DebugFeature } = require('./feature/debug/DebugFeature')
const { IdempotencyFeature } = require('./feature/idempotency/IdempotencyFeature')
const { LogFeature } = require('./feature/log/LogFeature')
const { MetricsFeature } = require('./feature/metrics/MetricsFeature')
const { NetsimFeature } = require('./feature/netsim/NetsimFeature')
const { PagingFeature } = require('./feature/paging/PagingFeature')
const { ProxyFeature } = require('./feature/proxy/ProxyFeature')
const { RatelimitFeature } = require('./feature/ratelimit/RatelimitFeature')
const { RbacFeature } = require('./feature/rbac/RbacFeature')
const { RetryFeature } = require('./feature/retry/RetryFeature')
const { SecretsFeature } = require('./feature/secrets/SecretsFeature')
const { StreamingFeature } = require('./feature/streaming/StreamingFeature')
const { TelemetryFeature } = require('./feature/telemetry/TelemetryFeature')
const { TestFeature } = require('./feature/test/TestFeature')
const { TimeoutFeature } = require('./feature/timeout/TimeoutFeature')
const { boru } = require('./feature/secrets/sekreto/plugins/boru')
const { hashicorp } = require('./feature/secrets/sekreto/plugins/hashicorp')



const FEATURE_CLASS = {
   audit: AuditFeature,
 cache: CacheFeature,
 clienttrack: ClienttrackFeature,
 cost: CostFeature,
 debug: DebugFeature,
 idempotency: IdempotencyFeature,
 log: LogFeature,
 metrics: MetricsFeature,
 netsim: NetsimFeature,
 paging: PagingFeature,
 proxy: ProxyFeature,
 ratelimit: RatelimitFeature,
 rbac: RbacFeature,
 retry: RetryFeature,
 secrets: SecretsFeature,
 streaming: StreamingFeature,
 telemetry: TelemetryFeature,
 test: TestFeature,
 timeout: TimeoutFeature,

}


// Per-feature plugin DEFINITIONS (voxgig/plugin `Definition` values), from
// the model's active plugin groups. A feature that takes a `plugins` option
// (secrets over sekreto) reads its own entry; a feature with no plugins has
// none. Named requires above make each definition statically reachable, so
// an SDK carries exactly the plugin modules its model selects — the same
// leanness the old side-effect registry imports bought, without a registry.
//
// Read by SecretsFeature through a DEFERRED require of this module: the
// requires above make the pair circular, and this file replaces
// module.exports at the end of its body, so anything reading the map at
// module load would get undefined. See tm/js/src/feature/secrets.
const FEATURE_PLUGINS = {
   secrets: [boru, hashicorp],

}


class Config {

  makeFeature(fn) {
    const fc = FEATURE_CLASS[fn]
    const fi = new fc()
    // TODO: errors etc
    return fi
  }

  // False for a feature added at runtime via options.extend (station's
  // adopt path) - the constructor uses this to skip makeFeature for names
  // no generated class backs.
  hasFeature(fn) {
    return null != FEATURE_CLASS[fn]
  }


  main = {
    name: 'Univec',
        slug: "univec",
    version: "0.1.2",
    target: "js",

  }


  feature = {
     audit:     {
      "options": {
        "active": false,
        "actor": "anonymous",
        "max": 1000
      },
      "optspec": {
        "now": "`$FUNCTION`",
        "sink": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "none"
    },
 cache:     {
      "options": {
        "active": false,
        "max": 256,
        "methods": [
          "GET"
        ],
        "ttl": 5000
      },
      "optspec": {
        "now": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "wrap"
    },
 clienttrack:     {
      "options": {
        "active": false,
        "clientVersion": "0.0.1"
      },
      "optspec": {
        "clientName": "`$STRING`",
        "clientVersion": "`$STRING`",
        "headers": "`$MAP`",
        "idgen": "`$FUNCTION`",
        "sessionId": "`$STRING`"
      },
      "strict": false,
      "transport": "none"
    },
 cost:     {
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
      "optspec": {
        "actor": "`$STRING`",
        "sink": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "wrap"
    },
 debug:     {
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
      "optspec": {
        "now": "`$FUNCTION`",
        "onEntry": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "none"
    },
 idempotency:     {
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
      "optspec": {
        "keygen": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "none"
    },
 log:     {
      "options": {
        "active": true
      },
      "optspec": {
        "level": "`$STRING`",
        "logger": "`$ANY`"
      },
      "strict": false,
      "transport": "none"
    },
 metrics:     {
      "options": {
        "active": false
      },
      "optspec": {
        "now": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "none"
    },
 netsim:     {
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
      "optspec": {
        "latency": [
          "`$ONE`",
          "`$NUMBER`",
          "`$MAP`"
        ],
        "sleep": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "wrap"
    },
 paging:     {
      "options": {
        "active": false,
        "afterVar": "after",
        "cursorParam": "cursor",
        "firstVar": "first",
        "limitParam": "limit",
        "pageParam": "page",
        "startPage": 1
      },
      "optspec": {
        "limit": "`$NUMBER`",
        "ops": "`$LIST`"
      },
      "strict": false,
      "transport": "none"
    },
 proxy:     {
      "options": {
        "active": false,
        "fromEnv": false,
        "noProxy": [],
        "url": ""
      },
      "optspec": {
        "agent": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "wrap"
    },
 ratelimit:     {
      "options": {
        "active": false,
        "burst": 5,
        "rate": 5
      },
      "optspec": {
        "now": "`$FUNCTION`",
        "sleep": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "wrap"
    },
 rbac:     {
      "options": {
        "active": false,
        "deny": false,
        "permissions": [],
        "rules": {}
      },
      "optspec": {},
      "strict": false,
      "transport": "none"
    },
 retry:     {
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
      "optspec": {
        "jitter": "`$BOOLEAN`",
        "sleep": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "wrap"
    },
 secrets:     {
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
      "optspec": {},
      "strict": false,
      "transport": "wrap"
    },
 streaming:     {
      "options": {
        "active": false,
        "chunkDelay": 0,
        "chunkSize": 0
      },
      "optspec": {
        "ops": "`$LIST`",
        "sleep": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "none"
    },
 telemetry:     {
      "options": {
        "active": false
      },
      "optspec": {
        "exporter": "`$FUNCTION`",
        "headers": "`$MAP`",
        "idgen": "`$FUNCTION`",
        "now": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "none"
    },
 test:     {
      "options": {
        "active": false
      },
      "optspec": {
        "entity": "`$MAP`",
        "net": "`$MAP`"
      },
      "strict": false,
      "transport": "base"
    },
 timeout:     {
      "options": {
        "active": false,
        "ms": 30000
      },
      "optspec": {
        "clearTimer": "`$FUNCTION`",
        "setTimer": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "wrap"
    },

  }


  options = {
    base: "https://api.univec.ai",

    auth: {
      prefix: 'Bearer',
    },

    headers: {
      "content-type": "application/json"
    },

    entity: {
      
        convert: {
        },
  
        embed: {
        },
  
        ephemeral_key: {
        },
  
        model: {
        },
  
    }
  }


  entity = {
    "convert": {
      "fields": [
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
  }
}


const config = new Config()

module.exports = {
  config,
  FEATURE_PLUGINS,
}

