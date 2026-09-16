// Univec Js SDK: generated schemas. Do not edit.
//
// Generated from the model: `main.kit.optspec` and each feature's
// `config.options` for OPTSPEC; entity `fields[].type` for ENTITYSPEC.

const OPTSPEC = {
  "allow": {
    "method": "GET,PUT,POST,PATCH,DELETE,OPTIONS",
    "op": "create,update,load,list,remove,command,direct,graphql"
  },
  "apikey": "",
  "auth": {
    "basic": false,
    "prefix": ""
  },
  "base": "http://localhost:8000",
  "clean": {
    "keys": "key,token,id"
  },
  "entity": {
    "`$CHILD`": {
      "`$OPEN`": true,
      "active": false,
      "alias": {}
    }
  },
  "extend": "`$ANY`",
  "headers": {
    "`$CHILD`": "`$STRING`"
  },
  "prefix": "",
  "secret": "",
  "server": {
    "`$CHILD`": ""
  },
  "suffix": "",
  "system": {
    "fetch": "`$ANY`"
  },
  "test": {
    "active": false,
    "entity": {
      "`$OPEN`": true
    }
  },
  "utility": {},
  "feature": {
    "`$CHILD`": {
      "`$OPEN`": true,
      "active": false
    },
    "audit": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "actor": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "max": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "now": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ],
        "sink": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "cache": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "max": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "methods": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ],
        "ttl": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "now": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "clienttrack": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "clientVersion": [
          "`$ONE`",
          "`$STRING`",
          "`$NIL`"
        ],
        "clientName": [
          "`$ONE`",
          "`$STRING`",
          "`$NIL`"
        ],
        "headers": [
          "`$ONE`",
          "`$MAP`",
          "`$NIL`"
        ],
        "idgen": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ],
        "sessionId": [
          "`$ONE`",
          "`$STRING`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "cost": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "budget": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "currency": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "header": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "onBudget": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "path": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "perUnit": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "rates": [
          "`$ONE`",
          "`$MAP`",
          "`$NIL`"
        ],
        "unit": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "actor": [
          "`$ONE`",
          "`$STRING`",
          "`$NIL`"
        ],
        "sink": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "debug": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "max": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "redact": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ],
        "now": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ],
        "onEntry": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "idempotency": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "header": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "methods": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ],
        "ops": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ],
        "keygen": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "log": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "level": [
          "`$ONE`",
          "`$STRING`",
          "`$NIL`"
        ],
        "logger": "`$ANY`"
      },
      "`$NIL`"
    ],
    "metrics": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "now": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "netsim": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "errorTimes": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "failEvery": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "failRate": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "failStatus": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "failTimes": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "latency": [
          "`$ONE`",
          "`$NUMBER`",
          "`$MAP`",
          "`$NIL`"
        ],
        "offline": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "rateLimitTimes": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "retryAfter": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "seed": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "sleep": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "paging": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "afterVar": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "cursorParam": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "firstVar": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "limitParam": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "pageParam": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "startPage": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "limit": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "ops": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "proxy": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "fromEnv": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "noProxy": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ],
        "url": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "agent": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "ratelimit": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "burst": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "rate": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "now": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ],
        "sleep": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "rbac": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "deny": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "permissions": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ],
        "rules": [
          "`$ONE`",
          "`$MAP`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "retry": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "factor": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "maxDelay": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "minDelay": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "retries": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "statuses": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ],
        "jitter": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "sleep": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "secrets": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "cache": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "exchange": [
          "`$ONE`",
          "`$MAP`",
          "`$NIL`"
        ],
        "name": [
          "`$ONE`",
          "`$STRING`",
          [
            "`$EXACT`",
            ""
          ],
          "`$NIL`"
        ],
        "providers": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "streaming": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "chunkDelay": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "chunkSize": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "ops": [
          "`$ONE`",
          "`$LIST`",
          "`$NIL`"
        ],
        "sleep": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "telemetry": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "exporter": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ],
        "headers": [
          "`$ONE`",
          "`$MAP`",
          "`$NIL`"
        ],
        "idgen": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ],
        "now": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "test": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "entity": [
          "`$ONE`",
          "`$MAP`",
          "`$NIL`"
        ],
        "net": [
          "`$ONE`",
          "`$MAP`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ],
    "timeout": [
      "`$ONE`",
      {
        "`$OPEN`": true,
        "active": [
          "`$ONE`",
          "`$BOOLEAN`",
          "`$NIL`"
        ],
        "ms": [
          "`$ONE`",
          "`$NUMBER`",
          "`$NIL`"
        ],
        "clearTimer": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ],
        "setTimer": [
          "`$ONE`",
          "`$FUNCTION`",
          "`$NIL`"
        ]
      },
      "`$NIL`"
    ]
  }
}

const ENTITYSPEC = {}

module.exports = {
  OPTSPEC,
  ENTITYSPEC,
}
