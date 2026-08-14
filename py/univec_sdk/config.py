# Univec SDK configuration


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
            "name": "bridge_model",
            "req": True,
            "type": "`$STRING`",
          },
          {
            "name": "embeddings",
            "req": True,
            "type": "`$ARRAY`",
          },
          {
            "name": "source_model",
            "req": True,
            "type": "`$STRING`",
          },
          {
            "name": "target_model",
            "req": True,
            "type": "`$STRING`",
          },
          {
            "name": "texts",
            "req": True,
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
                "parts": [
                  "v1",
                  "convert",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
              },
              {
                "args": {},
                "kind": "http",
                "method": "POST",
                "orig": "/v1/embed-bridge",
                "parts": [
                  "v1",
                  "embed-bridge",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
              },
              {
                "args": {},
                "kind": "http",
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
                  "res": "`body.data`",
                },
              },
              {
                "args": {},
                "kind": "http",
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
                  "res": "`body.data`",
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
            "req": True,
            "type": "`$ARRAY`",
          },
          {
            "name": "model",
            "req": True,
            "type": "`$STRING`",
          },
          {
            "name": "texts",
            "req": True,
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
                "parts": [
                  "v1",
                  "embed",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
                },
              },
              {
                "args": {},
                "kind": "http",
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
                  "res": "`body.data`",
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
            "req": True,
            "type": "`$INTEGER`",
          },
          {
            "name": "dailyUsed",
            "req": True,
            "type": "`$INTEGER`",
          },
          {
            "name": "key",
            "req": True,
            "type": "`$STRING`",
          },
          {
            "name": "resetsAt",
            "req": True,
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
                "parts": [
                  "v1",
                  "ephemeral",
                  "key",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
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
            "type": "`$OBJECT`",
          },
          {
            "name": "executionProvider",
            "type": "`$STRING`",
          },
          {
            "name": "modelCard",
            "type": "`$OBJECT`",
          },
          {
            "name": "modelType",
            "req": True,
            "type": "`$STRING`",
          },
          {
            "name": "name",
            "req": True,
            "type": "`$STRING`",
          },
          {
            "name": "sequenceLen",
            "type": "`$INTEGER`",
          },
          {
            "name": "sourceDim",
            "type": "`$INTEGER`",
          },
          {
            "name": "sourceModel",
            "type": "`$STRING`",
          },
          {
            "name": "targetDim",
            "req": True,
            "type": "`$INTEGER`",
          },
          {
            "name": "targetModel",
            "req": True,
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
                "parts": [
                  "v1",
                  "models",
                ],
                "select": {},
                "transform": {
                  "req": "`reqdata`",
                  "res": "`body.data`",
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
