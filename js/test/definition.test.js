const { describe, test } = require('node:test')
const { SDK } = require('..')
const { runDefinitionPoint } = require('./definition-runner')
const { isControlSkipped } = require('./utility')


// Generated from the API definition, not from the model this SDK was built
// from: the route, the declared query parameters, the credential the security
// scheme names, and the definition's own response example.
const PLAN = [
  {
    "entity": "convert",
    "accessor": "Convert",
    "op": "create",
    "method": "POST",
    "path": "/v1/convert",
    "args": [],
    "select": {},
    "headers": [],
    "cookies": [],
    "responseMedia": [
      "application/json"
    ],
    "query": [],
    "queryArgs": [],
    "auth": [
      [
        {
          "in": "header",
          "name": "authorization",
          "scheme": "bearer"
        }
      ]
    ],
    "status": 200,
    "sample": {
      "success": true,
      "data": {
        "embeddings": [
          [
            1
          ]
        ],
        "source_model": "x",
        "target_model": "x"
      }
    },
    "idField": "id"
  },
  {
    "entity": "convert",
    "accessor": "Convert",
    "op": "create",
    "method": "POST",
    "path": "/v1/embed-bridge",
    "action": "bridge",
    "args": [],
    "select": {},
    "headers": [],
    "cookies": [],
    "responseMedia": [
      "application/json"
    ],
    "query": [],
    "queryArgs": [],
    "auth": [
      [
        {
          "in": "header",
          "name": "authorization",
          "scheme": "bearer"
        }
      ]
    ],
    "status": 200,
    "sample": {
      "data": {
        "bridge_model": "x",
        "embeddings": [
          [
            1
          ]
        ],
        "model": "x",
        "target_model": "x"
      },
      "success": true
    },
    "idField": "id"
  },
  {
    "entity": "convert",
    "accessor": "Convert",
    "op": "create",
    "method": "POST",
    "path": "/v1/ephemeral/convert",
    "action": "ephemeral",
    "args": [],
    "select": {},
    "headers": [],
    "cookies": [],
    "responseMedia": [
      "application/json"
    ],
    "query": [],
    "queryArgs": [],
    "auth": [
      [
        {
          "in": "header",
          "name": "authorization",
          "scheme": "bearer"
        }
      ]
    ],
    "status": 200,
    "sample": {
      "success": true,
      "data": {
        "embeddings": [
          [
            1
          ]
        ],
        "source_model": "x",
        "target_model": "x"
      }
    },
    "idField": "id"
  },
  {
    "entity": "convert",
    "accessor": "Convert",
    "op": "create",
    "method": "POST",
    "path": "/v1/ephemeral/embed-bridge",
    "action": "ephemeral_bridge",
    "args": [],
    "select": {},
    "headers": [],
    "cookies": [],
    "responseMedia": [
      "application/json"
    ],
    "query": [],
    "queryArgs": [],
    "auth": [
      [
        {
          "in": "header",
          "name": "authorization",
          "scheme": "bearer"
        }
      ]
    ],
    "status": 200,
    "sample": {
      "data": {
        "bridge_model": "x",
        "embeddings": [
          [
            1
          ]
        ],
        "model": "x",
        "target_model": "x"
      },
      "success": true
    },
    "idField": "id"
  },
  {
    "entity": "embed",
    "accessor": "Embed",
    "op": "create",
    "method": "POST",
    "path": "/v1/embed",
    "args": [],
    "select": {},
    "headers": [],
    "cookies": [],
    "responseMedia": [
      "application/json"
    ],
    "query": [],
    "queryArgs": [],
    "auth": [
      [
        {
          "in": "header",
          "name": "authorization",
          "scheme": "bearer"
        }
      ]
    ],
    "status": 200,
    "sample": {
      "success": true,
      "data": {
        "embeddings": [
          [
            1
          ]
        ],
        "model": "x"
      }
    },
    "idField": "id"
  },
  {
    "entity": "embed",
    "accessor": "Embed",
    "op": "create",
    "method": "POST",
    "path": "/v1/ephemeral/embed",
    "action": "ephemeral",
    "args": [],
    "select": {},
    "headers": [],
    "cookies": [],
    "responseMedia": [
      "application/json"
    ],
    "query": [],
    "queryArgs": [],
    "auth": [
      [
        {
          "in": "header",
          "name": "authorization",
          "scheme": "bearer"
        }
      ]
    ],
    "status": 200,
    "sample": {
      "success": true,
      "data": {
        "embeddings": [
          [
            1
          ]
        ],
        "model": "x"
      }
    },
    "idField": "id"
  },
  {
    "entity": "ephemeral_key",
    "accessor": "EphemeralKey",
    "op": "create",
    "method": "POST",
    "path": "/v1/ephemeral/key",
    "args": [],
    "select": {},
    "headers": [],
    "cookies": [],
    "responseMedia": [
      "application/json"
    ],
    "query": [],
    "queryArgs": [],
    "auth": [],
    "status": 200,
    "sample": {
      "success": true,
      "data": {
        "key": "x",
        "dailyLimit": 1,
        "dailyUsed": 1,
        "resetsAt": "2026-01-01T00:00:00Z"
      }
    },
    "idField": "id"
  },
  {
    "entity": "model",
    "accessor": "Model",
    "op": "list",
    "method": "GET",
    "path": "/v1/models",
    "args": [],
    "select": {},
    "headers": [],
    "cookies": [],
    "responseMedia": [
      "application/json"
    ],
    "query": [],
    "queryArgs": [],
    "auth": [],
    "status": 200,
    "sample": {
      "data": [
        {
          "eval": {
            "cosine_mean": 1,
            "cosine_median": 1,
            "cosine_std": 1,
            "kendall_p_value": 1,
            "kendall_tau": 1,
            "mrr": 1,
            "p_at_1": 1,
            "p_at_10": 1,
            "p_at_5": 1
          },
          "executionProvider": "x",
          "modelCard": {},
          "modelType": "embed",
          "name": "x",
          "sequenceLen": 1,
          "sourceDim": 1,
          "sourceModel": "x",
          "targetDim": 1,
          "targetModel": "x"
        }
      ],
      "success": true
    },
    "idField": "id"
  }
]


describe('definition', () => {
  for (const point of PLAN) {
    test(point.entity + '.' + point.op + ' ' + point.method + ' ' + point.path, async (t) => {
      const control = isControlSkipped('entityOp', point.entity + '.' + point.op, 'definition')
      if (control.skip) {
        t.skip(control.reason || 'skipped via sdk-test-control.json')
        return
      }
      await runDefinitionPoint(SDK, point)
    })
  }
})
