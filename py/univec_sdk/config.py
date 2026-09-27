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
        "optspec": {
          "now": "`$FUNCTION`",
          "sink": "`$FUNCTION`",
        },
        "strict": False,
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
        "optspec": {
          "now": "`$FUNCTION`",
        },
        "strict": False,
        "transport": "wrap",
      },
            "clienttrack": {
        "options": {
          "active": False,
          "clientVersion": "0.0.1",
        },
        "optspec": {
          "clientName": "`$STRING`",
          "clientVersion": "`$STRING`",
          "headers": "`$MAP`",
          "idgen": "`$FUNCTION`",
          "sessionId": "`$STRING`",
        },
        "strict": False,
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
        "optspec": {
          "actor": "`$STRING`",
          "sink": "`$FUNCTION`",
        },
        "strict": False,
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
        "optspec": {
          "now": "`$FUNCTION`",
          "onEntry": "`$FUNCTION`",
        },
        "strict": False,
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
        "optspec": {
          "keygen": "`$FUNCTION`",
        },
        "strict": False,
        "transport": "none",
      },
            "log": {
        "options": {
          "active": True,
        },
        "optspec": {
          "level": "`$STRING`",
          "logger": "`$ANY`",
        },
        "strict": False,
        "transport": "none",
      },
            "metrics": {
        "options": {
          "active": False,
        },
        "optspec": {
          "now": "`$FUNCTION`",
        },
        "strict": False,
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
        "optspec": {
          "latency": [
            "`$ONE`",
            "`$NUMBER`",
            "`$MAP`",
          ],
          "sleep": "`$FUNCTION`",
        },
        "strict": False,
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
        "optspec": {
          "limit": "`$NUMBER`",
          "ops": "`$LIST`",
        },
        "strict": False,
        "transport": "none",
      },
            "proxy": {
        "options": {
          "active": False,
          "fromEnv": False,
          "noProxy": [],
          "url": "",
        },
        "optspec": {
          "agent": "`$FUNCTION`",
        },
        "strict": False,
        "transport": "wrap",
      },
            "ratelimit": {
        "options": {
          "active": False,
          "burst": 5,
          "rate": 5,
        },
        "optspec": {
          "now": "`$FUNCTION`",
          "sleep": "`$FUNCTION`",
        },
        "strict": False,
        "transport": "wrap",
      },
            "rbac": {
        "options": {
          "active": False,
          "deny": False,
          "permissions": [],
          "rules": {},
        },
        "optspec": {},
        "strict": False,
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
        "optspec": {
          "jitter": "`$BOOLEAN`",
          "sleep": "`$FUNCTION`",
        },
        "strict": False,
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
        "optspec": {},
        "strict": False,
        "transport": "wrap",
      },
            "streaming": {
        "options": {
          "active": False,
          "chunkDelay": 0,
          "chunkSize": 0,
        },
        "optspec": {
          "ops": "`$LIST`",
          "sleep": "`$FUNCTION`",
        },
        "strict": False,
        "transport": "none",
      },
            "telemetry": {
        "options": {
          "active": False,
        },
        "optspec": {
          "exporter": "`$FUNCTION`",
          "headers": "`$MAP`",
          "idgen": "`$FUNCTION`",
          "now": "`$FUNCTION`",
        },
        "strict": False,
        "transport": "none",
      },
            "test": {
        "options": {
          "active": False,
        },
        "optspec": {
          "entity": "`$MAP`",
          "net": "`$MAP`",
        },
        "strict": False,
        "transport": "base",
      },
            "timeout": {
        "options": {
          "active": False,
          "ms": 30000,
        },
        "optspec": {
          "clearTimer": "`$FUNCTION`",
          "setTimer": "`$FUNCTION`",
        },
        "strict": False,
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
            "name": "embeddings",
            "title": "Embeddings",
            "type": "`$ARRAY`",
            "req": True,
            "short": "Translated vectors, in the target model's dimension.",
          },
          {
            "name": "source_model",
            "title": "Source Model",
            "type": "`$STRING`",
            "req": True,
            "short": "Model space the supplied vectors are currently in.",
          },
          {
            "name": "target_model",
            "title": "Target Model",
            "type": "`$STRING`",
            "req": True,
            "short": "Model space to translate into.",
          },
        ],
        "name": "convert",
        "op": {
          "create": {
            "input": "data",
            "name": "create",
            "points": [
              {
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
                "parts": [
                  "v1",
                  "convert",
                ],
                "rename": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "args": {},
                "select": {},
                "live": {
                  "assert": {
                    "equal": {
                      "source_model": {
                        "from": "models",
                        "path": "sourceModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "target_model": {
                        "from": "models",
                        "path": "targetModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                    },
                    "vectors": {
                      "count": 1,
                      "dimension": {
                        "from": "models",
                        "path": "targetDim",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "path": "embeddings",
                    },
                  },
                  "auth": "account",
                  "id": "account-convert",
                  "input": {
                    "embeddings": {
                      "from": "account-embed",
                      "path": "embeddings",
                    },
                    "source_model": {
                      "from": "models",
                      "path": "sourceModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                    "target_model": {
                      "from": "models",
                      "path": "targetModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                  },
                },
              },
              {
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
                "parts": [
                  "v1",
                  "embed-bridge",
                ],
                "rename": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "args": {},
                "select": {
                  "$action": "bridge",
                },
                "live": {
                  "assert": {
                    "equal": {
                      "bridge_model": {
                        "from": "models",
                        "path": "sourceModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "target_model": {
                        "from": "models",
                        "path": "targetModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                    },
                    "vectors": {
                      "count": 1,
                      "dimension": {
                        "from": "models",
                        "path": "targetDim",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "path": "embeddings",
                    },
                  },
                  "auth": "account",
                  "id": "account-embed-bridge",
                  "input": {
                    "bridge_model": {
                      "from": "models",
                      "path": "sourceModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                    "target_model": {
                      "from": "models",
                      "path": "targetModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                    "texts": [
                      "SDK live coverage test.",
                    ],
                  },
                },
              },
              {
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
                "parts": [
                  "v1",
                  "ephemeral",
                  "convert",
                ],
                "rename": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "args": {},
                "select": {
                  "$action": "ephemeral",
                },
                "live": {
                  "assert": {
                    "equal": {
                      "source_model": {
                        "from": "models",
                        "path": "sourceModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "target_model": {
                        "from": "models",
                        "path": "targetModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                    },
                    "vectors": {
                      "count": 1,
                      "dimension": {
                        "from": "models",
                        "path": "targetDim",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "path": "embeddings",
                    },
                  },
                  "auth": "issued",
                  "credential": {
                    "from": "key",
                    "path": "key",
                  },
                  "id": "ephemeral-convert",
                  "input": {
                    "embeddings": {
                      "from": "ephemeral-embed",
                      "path": "embeddings",
                    },
                    "source_model": {
                      "from": "models",
                      "path": "sourceModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                    "target_model": {
                      "from": "models",
                      "path": "targetModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                  },
                },
              },
              {
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
                "parts": [
                  "v1",
                  "ephemeral",
                  "embed-bridge",
                ],
                "rename": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "args": {},
                "select": {
                  "$action": "ephemeral_bridge",
                },
                "live": {
                  "assert": {
                    "equal": {
                      "bridge_model": {
                        "from": "models",
                        "path": "sourceModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "target_model": {
                        "from": "models",
                        "path": "targetModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                    },
                    "vectors": {
                      "count": 1,
                      "dimension": {
                        "from": "models",
                        "path": "targetDim",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "path": "embeddings",
                    },
                  },
                  "auth": "issued",
                  "credential": {
                    "from": "key",
                    "path": "key",
                  },
                  "id": "ephemeral-embed-bridge",
                  "input": {
                    "bridge_model": {
                      "from": "models",
                      "path": "sourceModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                    "target_model": {
                      "from": "models",
                      "path": "targetModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                    "texts": [
                      "SDK live coverage test.",
                    ],
                  },
                },
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
            "title": "Embeddings",
            "type": "`$ARRAY`",
            "req": True,
            "short": "One vector per input text, in input order.",
          },
          {
            "name": "model",
            "title": "Model",
            "type": "`$STRING`",
            "req": True,
            "short": "Model that produced the vectors.",
          },
          {
            "name": "texts",
            "title": "Texts",
            "type": "`$ARRAY`",
            "req": True,
            "short": "Texts to embed.",
          },
        ],
        "name": "embed",
        "op": {
          "create": {
            "input": "data",
            "name": "create",
            "points": [
              {
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
                "parts": [
                  "v1",
                  "embed",
                ],
                "rename": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "args": {},
                "select": {},
                "live": {
                  "assert": {
                    "equal": {
                      "model": {
                        "from": "models",
                        "path": "sourceModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                    },
                    "vectors": {
                      "count": 1,
                      "dimension": {
                        "from": "models",
                        "path": "sourceDim",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "path": "embeddings",
                    },
                  },
                  "auth": "account",
                  "id": "account-embed",
                  "input": {
                    "model": {
                      "from": "models",
                      "path": "sourceModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                    "texts": [
                      "SDK live coverage test.",
                    ],
                  },
                },
              },
              {
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
                "parts": [
                  "v1",
                  "ephemeral",
                  "embed",
                ],
                "rename": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "args": {},
                "select": {
                  "$action": "ephemeral",
                },
                "live": {
                  "assert": {
                    "equal": {
                      "model": {
                        "from": "models",
                        "path": "sourceModel",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                    },
                    "vectors": {
                      "count": 1,
                      "dimension": {
                        "from": "models",
                        "path": "sourceDim",
                        "related": {
                          "foreign": "name",
                          "from": "models",
                          "local": "sourceModel",
                          "where": {
                            "modelType": "embed",
                          },
                        },
                        "where": {
                          "modelType": "convert",
                        },
                      },
                      "path": "embeddings",
                    },
                  },
                  "auth": "issued",
                  "credential": {
                    "from": "key",
                    "path": "key",
                  },
                  "id": "ephemeral-embed",
                  "input": {
                    "model": {
                      "from": "models",
                      "path": "sourceModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed",
                        },
                      },
                      "where": {
                        "modelType": "convert",
                      },
                    },
                    "texts": [
                      "SDK live coverage test.",
                    ],
                  },
                },
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
            "title": "Daily Limit",
            "type": "`$INTEGER`",
            "req": True,
            "short": "Calls permitted per day.",
          },
          {
            "name": "dailyUsed",
            "title": "Daily Used",
            "type": "`$INTEGER`",
            "req": True,
            "short": "Calls already used today.",
          },
          {
            "name": "key",
            "title": "Key",
            "type": "`$STRING`",
            "req": True,
            "short": "The ephemeral API key, prefixed `eph_`.",
          },
          {
            "name": "resetsAt",
            "title": "Resets At",
            "type": "`$STRING`",
            "req": True,
            "short": "When the daily allowance resets.",
            "format": "date-time",
          },
        ],
        "name": "ephemeral_key",
        "op": {
          "create": {
            "input": "data",
            "name": "create",
            "points": [
              {
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
                "parts": [
                  "v1",
                  "ephemeral",
                  "key",
                ],
                "rename": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "args": {},
                "select": {},
                "live": {
                  "assert": {
                    "nonempty": [
                      "key",
                    ],
                  },
                  "auth": "public",
                  "id": "key",
                  "retention": "No deletion endpoint; issued key is subject to the service daily allowance",
                },
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
            "title": "Eval",
            "type": "`$OBJECT`",
            "short": "Retrieval-fidelity metrics for a convert model.",
          },
          {
            "name": "executionProvider",
            "title": "Execution Provider",
            "type": "`$STRING`",
            "short": "Hardware backend, e.g.",
          },
          {
            "name": "modelCard",
            "title": "Model Card",
            "type": "`$OBJECT`",
            "short": "Convert models only: training provenance and architecture detail.",
          },
          {
            "name": "modelType",
            "title": "Model Type",
            "type": "`$STRING`",
            "req": True,
            "short": "`embed` for text-to-vector models, `convert` for space-translation models.",
          },
          {
            "name": "name",
            "title": "Name",
            "type": "`$STRING`",
            "req": True,
            "short": "Model identifier used in requests.",
          },
          {
            "name": "sequenceLen",
            "title": "Sequence Len",
            "type": "`$INTEGER`",
            "short": "Embed models only: maximum input sequence length.",
          },
          {
            "name": "sourceDim",
            "title": "Source Dim",
            "type": "`$INTEGER`",
            "short": "Convert models only: source vector dimension.",
          },
          {
            "name": "sourceModel",
            "title": "Source Model",
            "type": "`$STRING`",
            "short": "Convert models only: the source model space.",
          },
          {
            "name": "targetDim",
            "title": "Target Dim",
            "type": "`$INTEGER`",
            "req": True,
            "short": "Dimension of the produced vectors.",
          },
          {
            "name": "targetModel",
            "title": "Target Model",
            "type": "`$STRING`",
            "req": True,
            "short": "The model space produced.",
          },
        ],
        "name": "model",
        "op": {
          "list": {
            "input": "data",
            "name": "list",
            "points": [
              {
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
                "parts": [
                  "v1",
                  "models",
                ],
                "rename": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
                "args": {},
                "select": {},
                "live": {
                  "assert": {
                    "nonempty": [
                      "",
                    ],
                  },
                  "auth": "public",
                  "id": "models",
                },
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
