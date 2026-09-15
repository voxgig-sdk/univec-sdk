# Univec SDK configuration
from univec_sdk.feature.secrets.voxgig_sekreto.plugins.boru import boru
from univec_sdk.feature.secrets.voxgig_sekreto.plugins.hashicorp import hashicorp


# The sekreto plugin DEFINITIONS the model selected per feature, imported
# above by name from the modules the catalogue's active `plugin.def`
# entries declare. Handed to each feature (secrets builds its Sekreto
# with them): a provider kind not listed here is unknown to that SDK.
FEATURE_PLUGINS = {
    "secrets": [boru, hashicorp],
}


_shared_config = None


def shared_config():
    """Return the process-wide config, built once on first use.

    The SDK reads the config on every request and never writes to it, so one
    instance is shared by every client rather than rebuilt per client.

    The returned dict is shared: treat it as read-only. Callers that need to
    mutate should use make_config, which always returns a fresh copy.
    """
    global _shared_config
    if _shared_config is None:
        _shared_config = make_config()
    return _shared_config


def make_config():
    """Build a fresh, fully materialised config dict.

    Every call rebuilds the whole structure, so prefer shared_config unless
    you need a private copy you intend to mutate.
    """
    return {
        "main": {
            "name": "Univec",
            "slug": "univec",
            "version": "0.1.2",
            "target": "py",
        },
        "feature": {
            "audit": {
        "options": {
          "active": False,
          "actor": "anonymous",
          "max": 1000,
        },
        "transport": "none",
      },
            "cache": {
        "options": {
          "active": False,
          "max": 256,
          "methods": [
            "GET",
          ],
          "ttl": 5000,
        },
        "transport": "wrap",
      },
            "clienttrack": {
        "options": {
          "active": False,
          "clientVersion": "0.0.1",
        },
        "transport": "none",
      },
            "cost": {
        "options": {
          "active": False,
          "budget": 0,
          "currency": "USD",
          "header": "",
          "onBudget": "warn",
          "path": "",
          "perUnit": 0,
          "rates": {},
          "unit": 0,
        },
        "transport": "wrap",
      },
            "debug": {
        "options": {
          "active": False,
          "max": 100,
          "redact": [
            "authorization",
            "cookie",
            "set-cookie",
            "api-key",
            "apikey",
            "x-api-key",
            "idempotency-key",
          ],
        },
        "transport": "none",
      },
            "idempotency": {
        "options": {
          "active": False,
          "header": "Idempotency-Key",
          "methods": [
            "POST",
            "PUT",
            "PATCH",
            "DELETE",
          ],
          "ops": [
            "create",
            "update",
            "remove",
          ],
        },
        "transport": "none",
      },
            "log": {
        "options": {
          "active": True,
        },
        "transport": "none",
      },
            "metrics": {
        "options": {
          "active": False,
        },
        "transport": "none",
      },
            "netsim": {
        "options": {
          "active": False,
          "errorTimes": 0,
          "failEvery": 0,
          "failRate": 0,
          "failStatus": 503,
          "failTimes": 0,
          "latency": 0,
          "offline": False,
          "rateLimitTimes": 0,
          "retryAfter": 0,
          "seed": 1,
        },
        "transport": "wrap",
      },
            "paging": {
        "options": {
          "active": False,
          "afterVar": "after",
          "cursorParam": "cursor",
          "firstVar": "first",
          "limitParam": "limit",
          "pageParam": "page",
          "startPage": 1,
        },
        "transport": "none",
      },
            "proxy": {
        "options": {
          "active": False,
          "fromEnv": False,
          "noProxy": [],
          "url": "",
        },
        "transport": "wrap",
      },
            "ratelimit": {
        "options": {
          "active": False,
          "burst": 5,
          "rate": 5,
        },
        "transport": "wrap",
      },
            "rbac": {
        "options": {
          "active": False,
          "deny": False,
          "permissions": [],
          "rules": {},
        },
        "transport": "none",
      },
            "retry": {
        "options": {
          "active": False,
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
            504,
          ],
        },
        "transport": "wrap",
      },
            "secrets": {
        "options": {
          "active": False,
          "cache": True,
          "exchange": {
            "active": False,
            "method": "POST",
            "path": "auth/token",
            "refresh": "",
            "request": "refresh_token",
            "response": "access_token",
            "retries": 1,
            "statuses": [
              401,
            ],
          },
          "name": "univec",
          "providers": [
            {
              "kind": "boru",
              "namespace": "sdk",
            },
          ],
        },
        "transport": "wrap",
      },
            "streaming": {
        "options": {
          "active": False,
          "chunkDelay": 0,
          "chunkSize": 0,
        },
        "transport": "none",
      },
            "telemetry": {
        "options": {
          "active": False,
        },
        "transport": "none",
      },
            "test": {
        "options": {
          "active": False,
        },
        "transport": "base",
      },
            "timeout": {
        "options": {
          "active": False,
          "ms": 30000,
        },
        "transport": "wrap",
      },
        },
        "options": {
            "base": "https://api.univec.ai",
            "auth": {
                "prefix": "Bearer",
            },
            "headers": {
        "content-type": "application/json",
      },
            "entity": {
                "convert": {},
                "embed": {},
                "ephemeral_key": {},
                "model": {},
            },
        },
        "entity": {
      "convert": {
        "fields": [
          {
            "name": "bridge_model",
            "req": True,
            "short": "Embed model used to vectorise the text before translation.",
            "type": "`$STRING`",
          },
          {
            "name": "embeddings",
            "req": True,
            "short": "Translated vectors, in the target model's dimension.",
            "type": "`$ARRAY`",
          },
          {
            "name": "source_model",
            "req": True,
            "short": "Model space the supplied vectors are currently in.",
            "type": "`$STRING`",
          },
          {
            "name": "target_model",
            "req": True,
            "short": "Model space to translate into.",
            "type": "`$STRING`",
          },
          {
            "name": "texts",
            "req": True,
            "short": "Texts to embed and translate.",
            "type": "`$ARRAY`",
          },
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
                    "lit": "v1",
                  },
                  {
                    "lit": "convert",
                  },
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "parts": [
                  "v1",
                  "convert",
                ],
              },
              {
                "args": {},
                "kind": "http",
                "method": "POST",
                "orig": "/v1/embed-bridge",
                "segments": [
                  {
                    "lit": "v1",
                  },
                  {
                    "lit": "embed-bridge",
                  },
                ],
                "select": {
                  "$action": "bridge",
                },
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "parts": [
                  "v1",
                  "embed-bridge",
                ],
              },
              {
                "args": {},
                "kind": "http",
                "method": "POST",
                "orig": "/v1/ephemeral/convert",
                "segments": [
                  {
                    "lit": "v1",
                  },
                  {
                    "lit": "ephemeral",
                  },
                  {
                    "lit": "convert",
                  },
                ],
                "select": {
                  "$action": "ephemeral",
                },
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "parts": [
                  "v1",
                  "ephemeral",
                  "convert",
                ],
              },
              {
                "args": {},
                "kind": "http",
                "method": "POST",
                "orig": "/v1/ephemeral/embed-bridge",
                "segments": [
                  {
                    "lit": "v1",
                  },
                  {
                    "lit": "ephemeral",
                  },
                  {
                    "lit": "embed-bridge",
                  },
                ],
                "select": {
                  "$action": "ephemeral_bridge",
                },
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "parts": [
                  "v1",
                  "ephemeral",
                  "embed-bridge",
                ],
              },
            ],
          },
        },
        "relations": {
          "ancestors": [],
        },
      },
      "embed": {
        "fields": [
          {
            "name": "embeddings",
            "req": True,
            "short": "One vector per input text, in input order.",
            "type": "`$ARRAY`",
          },
          {
            "name": "model",
            "req": True,
            "short": "Model that produced the vectors.",
            "type": "`$STRING`",
          },
          {
            "name": "texts",
            "req": True,
            "short": "Texts to embed.",
            "type": "`$ARRAY`",
          },
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
                    "lit": "v1",
                  },
                  {
                    "lit": "embed",
                  },
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "parts": [
                  "v1",
                  "embed",
                ],
              },
              {
                "args": {},
                "kind": "http",
                "method": "POST",
                "orig": "/v1/ephemeral/embed",
                "segments": [
                  {
                    "lit": "v1",
                  },
                  {
                    "lit": "ephemeral",
                  },
                  {
                    "lit": "embed",
                  },
                ],
                "select": {
                  "$action": "ephemeral",
                },
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "parts": [
                  "v1",
                  "ephemeral",
                  "embed",
                ],
              },
            ],
          },
        },
        "relations": {
          "ancestors": [],
        },
      },
      "ephemeral_key": {
        "fields": [
          {
            "name": "dailyLimit",
            "req": True,
            "short": "Calls permitted per day.",
            "type": "`$INTEGER`",
          },
          {
            "name": "dailyUsed",
            "req": True,
            "short": "Calls already used today.",
            "type": "`$INTEGER`",
          },
          {
            "name": "key",
            "req": True,
            "short": "The ephemeral API key, prefixed `eph_`.",
            "type": "`$STRING`",
          },
          {
            "format": "date-time",
            "name": "resetsAt",
            "req": True,
            "short": "When the daily allowance resets.",
            "type": "`$STRING`",
          },
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
                    "lit": "v1",
                  },
                  {
                    "lit": "ephemeral",
                  },
                  {
                    "lit": "key",
                  },
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "parts": [
                  "v1",
                  "ephemeral",
                  "key",
                ],
              },
            ],
          },
        },
        "relations": {
          "ancestors": [],
        },
      },
      "model": {
        "fields": [
          {
            "name": "eval",
            "short": "Retrieval-fidelity metrics for a convert model.",
            "type": "`$OBJECT`",
          },
          {
            "name": "executionProvider",
            "short": "Hardware backend, e.g.",
            "type": "`$STRING`",
          },
          {
            "name": "modelCard",
            "short": "Convert models only: training provenance and architecture detail.",
            "type": "`$OBJECT`",
          },
          {
            "name": "modelType",
            "req": True,
            "short": "`embed` for text-to-vector models, `convert` for space-translation models.",
            "type": "`$STRING`",
          },
          {
            "name": "name",
            "req": True,
            "short": "Model identifier used in requests.",
            "type": "`$STRING`",
          },
          {
            "name": "sequenceLen",
            "short": "Embed models only: maximum input sequence length.",
            "type": "`$INTEGER`",
          },
          {
            "name": "sourceDim",
            "short": "Convert models only: source vector dimension.",
            "type": "`$INTEGER`",
          },
          {
            "name": "sourceModel",
            "short": "Convert models only: the source model space.",
            "type": "`$STRING`",
          },
          {
            "name": "targetDim",
            "req": True,
            "short": "Dimension of the produced vectors.",
            "type": "`$INTEGER`",
          },
          {
            "name": "targetModel",
            "req": True,
            "short": "The model space produced.",
            "type": "`$STRING`",
          },
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
                    "lit": "v1",
                  },
                  {
                    "lit": "models",
                  },
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "parts": [
                  "v1",
                  "models",
                ],
              },
            ],
          },
        },
        "relations": {
          "ancestors": [],
        },
      },
    },
    }
