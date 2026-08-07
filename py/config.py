# Univec SDK configuration


def make_config():
    return {
        "main": {
            "name": "Univec",
        },
        "feature": {
            "test": {
        "options": {
          "active": False,
        },
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
            "active": True,
            "name": "bridge_model",
            "req": True,
            "type": "`$STRING`",
            "index$": 0,
          },
          {
            "active": True,
            "name": "data",
            "req": True,
            "type": "`$OBJECT`",
            "index$": 1,
          },
          {
            "active": True,
            "name": "embedding",
            "req": True,
            "type": "`$ARRAY`",
            "index$": 2,
          },
          {
            "active": True,
            "name": "source_model",
            "req": True,
            "type": "`$STRING`",
            "index$": 3,
          },
          {
            "active": True,
            "name": "success",
            "req": True,
            "type": "`$BOOLEAN`",
            "index$": 4,
          },
          {
            "active": True,
            "name": "target_model",
            "req": True,
            "type": "`$STRING`",
            "index$": 5,
          },
          {
            "active": True,
            "name": "text",
            "req": True,
            "type": "`$ARRAY`",
            "index$": 6,
          },
        ],
        "name": "convert",
        "op": {
          "create": {
            "input": "data",
            "name": "create",
            "points": [
              {
                "active": True,
                "args": {},
                "method": "POST",
                "orig": "/v1/convert",
                "parts": [
                  "v1",
                  "convert",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body`",
                },
                "index$": 0,
              },
              {
                "active": True,
                "args": {},
                "method": "POST",
                "orig": "/v1/embed-bridge",
                "parts": [
                  "v1",
                  "embed-bridge",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body`",
                },
                "index$": 1,
              },
              {
                "active": True,
                "args": {},
                "method": "POST",
                "orig": "/v1/ephemeral/convert",
                "parts": [
                  "v1",
                  "ephemeral",
                  "convert",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body`",
                },
                "index$": 2,
              },
              {
                "active": True,
                "args": {},
                "method": "POST",
                "orig": "/v1/ephemeral/embed-bridge",
                "parts": [
                  "v1",
                  "ephemeral",
                  "embed-bridge",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body`",
                },
                "index$": 3,
              },
            ],
            "key$": "create",
          },
        },
        "relations": {
          "ancestors": [],
        },
      },
      "embed": {
        "fields": [
          {
            "active": True,
            "name": "data",
            "req": True,
            "type": "`$OBJECT`",
            "index$": 0,
          },
          {
            "active": True,
            "name": "model",
            "req": True,
            "type": "`$STRING`",
            "index$": 1,
          },
          {
            "active": True,
            "name": "success",
            "req": True,
            "type": "`$BOOLEAN`",
            "index$": 2,
          },
          {
            "active": True,
            "name": "text",
            "req": True,
            "type": "`$ARRAY`",
            "index$": 3,
          },
        ],
        "name": "embed",
        "op": {
          "create": {
            "input": "data",
            "name": "create",
            "points": [
              {
                "active": True,
                "args": {},
                "method": "POST",
                "orig": "/v1/embed",
                "parts": [
                  "v1",
                  "embed",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body`",
                },
                "index$": 0,
              },
              {
                "active": True,
                "args": {},
                "method": "POST",
                "orig": "/v1/ephemeral/embed",
                "parts": [
                  "v1",
                  "ephemeral",
                  "embed",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body`",
                },
                "index$": 1,
              },
            ],
            "key$": "create",
          },
        },
        "relations": {
          "ancestors": [],
        },
      },
      "ephemeral_key": {
        "fields": [
          {
            "active": True,
            "name": "data",
            "req": True,
            "type": "`$OBJECT`",
            "index$": 0,
          },
          {
            "active": True,
            "name": "success",
            "req": True,
            "type": "`$BOOLEAN`",
            "index$": 1,
          },
        ],
        "name": "ephemeral_key",
        "op": {
          "create": {
            "input": "data",
            "name": "create",
            "points": [
              {
                "active": True,
                "args": {},
                "method": "POST",
                "orig": "/v1/ephemeral/key",
                "parts": [
                  "v1",
                  "ephemeral",
                  "key",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body`",
                },
                "index$": 0,
              },
            ],
            "key$": "create",
          },
        },
        "relations": {
          "ancestors": [],
        },
      },
      "model": {
        "fields": [
          {
            "active": True,
            "name": "eval",
            "req": False,
            "type": "`$OBJECT`",
            "index$": 0,
          },
          {
            "active": True,
            "name": "execution_provider",
            "req": False,
            "type": "`$STRING`",
            "index$": 1,
          },
          {
            "active": True,
            "name": "model_card",
            "req": False,
            "type": "`$OBJECT`",
            "index$": 2,
          },
          {
            "active": True,
            "name": "model_type",
            "req": True,
            "type": "`$STRING`",
            "index$": 3,
          },
          {
            "active": True,
            "name": "name",
            "req": True,
            "type": "`$STRING`",
            "index$": 4,
          },
          {
            "active": True,
            "name": "sequence_len",
            "req": False,
            "type": "`$INTEGER`",
            "index$": 5,
          },
          {
            "active": True,
            "name": "source_dim",
            "req": False,
            "type": "`$INTEGER`",
            "index$": 6,
          },
          {
            "active": True,
            "name": "source_model",
            "req": False,
            "type": "`$STRING`",
            "index$": 7,
          },
          {
            "active": True,
            "name": "target_dim",
            "req": True,
            "type": "`$INTEGER`",
            "index$": 8,
          },
          {
            "active": True,
            "name": "target_model",
            "req": True,
            "type": "`$STRING`",
            "index$": 9,
          },
        ],
        "name": "model",
        "op": {
          "list": {
            "input": "data",
            "name": "list",
            "points": [
              {
                "active": True,
                "args": {},
                "method": "GET",
                "orig": "/v1/models",
                "parts": [
                  "v1",
                  "models",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body`",
                },
                "index$": 0,
              },
            ],
            "key$": "list",
          },
        },
        "relations": {
          "ancestors": [],
        },
      },
    },
    }
