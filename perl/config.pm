# Univec SDK configuration

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }

# The vendored sekreto and plugin ports keep their UPSTREAM package layout,
# so they resolve through @INC rather than a file-path require - the same
# convention feature/secrets_feature.pm and t/omni.pm use. This BEGIN runs
# before the 'use' lines below, which are compile-time.
BEGIN {
  unshift @INC,
    "$__dir/feature/secrets/sekreto",
    "$__dir/feature/secrets/plugin",
    "$__dir/feature/secrets/plugins";
}
require(Cwd::abs_path("$__dir/lib/Voxgig/Struct.pm"));

package UnivecConfig;

use Voxgig::Sekreto::Plugins::Boru qw(boru);
use Voxgig::Sekreto::Plugins::Hashicorp qw(hashicorp);

# GENERATED from the API model - do not edit by hand. Parsed fresh on
# each call so callers can safely mutate their copy.
my $CONFIG_JSON = <<'END_CONFIG_JSON';
{
  "main": {
    "name": "Univec",
    "slug": "univec",
    "version": "0.1.2",
    "target": "perl"
  },
  "feature": {
    "audit": {
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
    "cache": {
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
    "clienttrack": {
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
    "cost": {
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
    "debug": {
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
    "idempotency": {
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
    "log": {
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
    "metrics": {
      "options": {
        "active": false
      },
      "optspec": {
        "now": "`$FUNCTION`"
      },
      "strict": false,
      "transport": "none"
    },
    "netsim": {
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
    "paging": {
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
    "proxy": {
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
    "ratelimit": {
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
    "rbac": {
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
    "retry": {
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
    "secrets": {
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
    "streaming": {
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
    "telemetry": {
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
    "test": {
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
    "timeout": {
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
    }
  },
  "options": {
    "base": "https://api.univec.ai",
    "auth": {
      "prefix": "Bearer"
    },
    "headers": {
      "content-type": "application/json"
    },
    "entity": {
      "convert": {},
      "embed": {},
      "ephemeral_key": {},
      "model": {}
    }
  },
  "entity": {
    "convert": {
      "fields": [
        {
          "name": "embeddings",
          "title": "Embeddings",
          "type": "`$ARRAY`",
          "req": true,
          "short": "Translated vectors, in the target model's dimension."
        },
        {
          "name": "source_model",
          "title": "Source Model",
          "type": "`$STRING`",
          "req": true,
          "short": "Model space the supplied vectors are currently in."
        },
        {
          "name": "target_model",
          "title": "Target Model",
          "type": "`$STRING`",
          "req": true,
          "short": "Model space to translate into."
        }
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
                  "lit": "v1"
                },
                {
                  "lit": "convert"
                }
              ],
              "parts": [
                "v1",
                "convert"
              ],
              "rename": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "target_model": {
                      "from": "models",
                      "path": "targetModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    }
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "path": "embeddings"
                  }
                },
                "auth": "account",
                "id": "account-convert",
                "input": {
                  "embeddings": {
                    "from": "account-embed",
                    "path": "embeddings"
                  },
                  "source_model": {
                    "from": "models",
                    "path": "sourceModel",
                    "related": {
                      "foreign": "name",
                      "from": "models",
                      "local": "sourceModel",
                      "where": {
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  },
                  "target_model": {
                    "from": "models",
                    "path": "targetModel",
                    "related": {
                      "foreign": "name",
                      "from": "models",
                      "local": "sourceModel",
                      "where": {
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  }
                }
              }
            },
            {
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
              "parts": [
                "v1",
                "embed-bridge"
              ],
              "rename": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              },
              "args": {},
              "select": {
                "$action": "bridge"
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "target_model": {
                      "from": "models",
                      "path": "targetModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    }
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "path": "embeddings"
                  }
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
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  },
                  "target_model": {
                    "from": "models",
                    "path": "targetModel",
                    "related": {
                      "foreign": "name",
                      "from": "models",
                      "local": "sourceModel",
                      "where": {
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  },
                  "texts": [
                    "SDK live coverage test."
                  ]
                }
              }
            },
            {
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
              "parts": [
                "v1",
                "ephemeral",
                "convert"
              ],
              "rename": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              },
              "args": {},
              "select": {
                "$action": "ephemeral"
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "target_model": {
                      "from": "models",
                      "path": "targetModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    }
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "path": "embeddings"
                  }
                },
                "auth": "issued",
                "credential": {
                  "from": "key",
                  "path": "key"
                },
                "id": "ephemeral-convert",
                "input": {
                  "embeddings": {
                    "from": "ephemeral-embed",
                    "path": "embeddings"
                  },
                  "source_model": {
                    "from": "models",
                    "path": "sourceModel",
                    "related": {
                      "foreign": "name",
                      "from": "models",
                      "local": "sourceModel",
                      "where": {
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  },
                  "target_model": {
                    "from": "models",
                    "path": "targetModel",
                    "related": {
                      "foreign": "name",
                      "from": "models",
                      "local": "sourceModel",
                      "where": {
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  }
                }
              }
            },
            {
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
              "parts": [
                "v1",
                "ephemeral",
                "embed-bridge"
              ],
              "rename": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              },
              "args": {},
              "select": {
                "$action": "ephemeral_bridge"
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "target_model": {
                      "from": "models",
                      "path": "targetModel",
                      "related": {
                        "foreign": "name",
                        "from": "models",
                        "local": "sourceModel",
                        "where": {
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    }
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "path": "embeddings"
                  }
                },
                "auth": "issued",
                "credential": {
                  "from": "key",
                  "path": "key"
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
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  },
                  "target_model": {
                    "from": "models",
                    "path": "targetModel",
                    "related": {
                      "foreign": "name",
                      "from": "models",
                      "local": "sourceModel",
                      "where": {
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  },
                  "texts": [
                    "SDK live coverage test."
                  ]
                }
              }
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
          "title": "Embeddings",
          "type": "`$ARRAY`",
          "req": true,
          "short": "One vector per input text, in input order."
        },
        {
          "name": "model",
          "title": "Model",
          "type": "`$STRING`",
          "req": true,
          "short": "Model that produced the vectors."
        },
        {
          "name": "texts",
          "title": "Texts",
          "type": "`$ARRAY`",
          "req": true,
          "short": "Texts to embed."
        }
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
                  "lit": "v1"
                },
                {
                  "lit": "embed"
                }
              ],
              "parts": [
                "v1",
                "embed"
              ],
              "rename": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    }
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "path": "embeddings"
                  }
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
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  },
                  "texts": [
                    "SDK live coverage test."
                  ]
                }
              }
            },
            {
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
              "parts": [
                "v1",
                "ephemeral",
                "embed"
              ],
              "rename": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              },
              "args": {},
              "select": {
                "$action": "ephemeral"
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    }
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
                          "modelType": "embed"
                        }
                      },
                      "where": {
                        "modelType": "convert"
                      }
                    },
                    "path": "embeddings"
                  }
                },
                "auth": "issued",
                "credential": {
                  "from": "key",
                  "path": "key"
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
                        "modelType": "embed"
                      }
                    },
                    "where": {
                      "modelType": "convert"
                    }
                  },
                  "texts": [
                    "SDK live coverage test."
                  ]
                }
              }
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
          "title": "Daily Limit",
          "type": "`$INTEGER`",
          "req": true,
          "short": "Calls permitted per day."
        },
        {
          "name": "dailyUsed",
          "title": "Daily Used",
          "type": "`$INTEGER`",
          "req": true,
          "short": "Calls already used today."
        },
        {
          "name": "key",
          "title": "Key",
          "type": "`$STRING`",
          "req": true,
          "short": "The ephemeral API key, prefixed `eph_`."
        },
        {
          "name": "resetsAt",
          "title": "Resets At",
          "type": "`$STRING`",
          "req": true,
          "short": "When the daily allowance resets.",
          "format": "date-time"
        }
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
                  "lit": "v1"
                },
                {
                  "lit": "ephemeral"
                },
                {
                  "lit": "key"
                }
              ],
              "parts": [
                "v1",
                "ephemeral",
                "key"
              ],
              "rename": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              },
              "args": {},
              "select": {},
              "live": {
                "assert": {
                  "nonempty": [
                    "key"
                  ]
                },
                "auth": "public",
                "id": "key",
                "retention": "No deletion endpoint; issued key is subject to the service daily allowance"
              }
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
          "title": "Eval",
          "type": "`$OBJECT`",
          "short": "Retrieval-fidelity metrics for a convert model."
        },
        {
          "name": "executionProvider",
          "title": "Execution Provider",
          "type": "`$STRING`",
          "short": "Hardware backend, e.g."
        },
        {
          "name": "modelCard",
          "title": "Model Card",
          "type": "`$OBJECT`",
          "short": "Convert models only: training provenance and architecture detail."
        },
        {
          "name": "modelType",
          "title": "Model Type",
          "type": "`$STRING`",
          "req": true,
          "short": "`embed` for text-to-vector models, `convert` for space-translation models."
        },
        {
          "name": "name",
          "title": "Name",
          "type": "`$STRING`",
          "req": true,
          "short": "Model identifier used in requests."
        },
        {
          "name": "sequenceLen",
          "title": "Sequence Len",
          "type": "`$INTEGER`",
          "short": "Embed models only: maximum input sequence length."
        },
        {
          "name": "sourceDim",
          "title": "Source Dim",
          "type": "`$INTEGER`",
          "short": "Convert models only: source vector dimension."
        },
        {
          "name": "sourceModel",
          "title": "Source Model",
          "type": "`$STRING`",
          "short": "Convert models only: the source model space."
        },
        {
          "name": "targetDim",
          "title": "Target Dim",
          "type": "`$INTEGER`",
          "req": true,
          "short": "Dimension of the produced vectors."
        },
        {
          "name": "targetModel",
          "title": "Target Model",
          "type": "`$STRING`",
          "req": true,
          "short": "The model space produced."
        }
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
                  "lit": "v1"
                },
                {
                  "lit": "models"
                }
              ],
              "parts": [
                "v1",
                "models"
              ],
              "rename": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              },
              "args": {},
              "select": {},
              "live": {
                "assert": {
                  "nonempty": [
                    ""
                  ]
                },
                "auth": "public",
                "id": "models"
              }
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
END_CONFIG_JSON

sub make_config {
  return Voxgig::Struct::parse_json($CONFIG_JSON);
}

# SHARED CONFIG (sdkgen rung L2).
#
# The SDK reads the config on every request and never writes to it, so one
# instance is shared by every client rather than rebuilt per client - the
# difference between parsing the embedded JSON once and once per client.
#
# The returned structure is SHARED: treat it as read-only. Callers that need to
# mutate should use make_config, which always parses a fresh copy.
my $SHARED_CONFIG;

sub shared_config {
  $SHARED_CONFIG = make_config() unless defined $SHARED_CONFIG;
  return $SHARED_CONFIG;
}

sub make_feature {
  my ($name) = @_;
  require(Cwd::abs_path("$__dir/features.pm"));
  return UnivecFeatures::make_feature($name);
}

# THE SDK'S PROVIDER VOCABULARY, from the model's active plugin groups.
#
# sekreto's core ships four built-in kinds (env, memory, dotenv, file) and
# nothing else: a kind not passed in here is UNKNOWN to that Sekreto. So
# this table is what decides which vault, cloud, SaaS or CLI providers a
# chain in this SDK may name - and an inactive group is not merely
# unimported, its module is not generated at all.
our %FEATURE_PLUGINS = (
  'secrets' => [ boru(), hashicorp() ],
);

sub feature_plugins {
  my ($name) = @_;
  $name = '' unless defined $name;
  my $list = $FEATURE_PLUGINS{$name};
  return defined $list ? $list : [];
}

1;
