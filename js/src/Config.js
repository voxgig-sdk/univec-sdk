
const { BaseFeature } = require('./feature/base/BaseFeature')
const { TestFeature } = require('./feature/test/TestFeature')



const FEATURE_CLASS = {
   test: TestFeature,

}


class Config {

  makeFeature(fn) {
    const fc = FEATURE_CLASS[fn]
    const fi = new fc()
    // TODO: errors etc
    return fi
  }


  main = {
    name: 'Univec',
  }


  feature = {
     test:     {
      "options": {
        "active": false
      }
    },

  }


  options = {
    base: 'https://api.univec.ai',

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
          "name": "bridge_model",
          "req": true,
          "type": "`$STRING`"
        },
        {
          "name": "embeddings",
          "req": true,
          "type": "`$ARRAY`"
        },
        {
          "name": "source_model",
          "req": true,
          "type": "`$STRING`"
        },
        {
          "name": "target_model",
          "req": true,
          "type": "`$STRING`"
        },
        {
          "name": "texts",
          "req": true,
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
              "parts": [
                "v1",
                "convert"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              }
            },
            {
              "args": {},
              "kind": "http",
              "method": "POST",
              "orig": "/v1/embed-bridge",
              "parts": [
                "v1",
                "embed-bridge"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              }
            },
            {
              "args": {},
              "kind": "http",
              "method": "POST",
              "orig": "/v1/ephemeral/convert",
              "parts": [
                "v1",
                "ephemeral",
                "convert"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              }
            },
            {
              "args": {},
              "kind": "http",
              "method": "POST",
              "orig": "/v1/ephemeral/embed-bridge",
              "parts": [
                "v1",
                "ephemeral",
                "embed-bridge"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
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
          "req": true,
          "type": "`$ARRAY`"
        },
        {
          "name": "model",
          "req": true,
          "type": "`$STRING`"
        },
        {
          "name": "texts",
          "req": true,
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
              "parts": [
                "v1",
                "embed"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
              }
            },
            {
              "args": {},
              "kind": "http",
              "method": "POST",
              "orig": "/v1/ephemeral/embed",
              "parts": [
                "v1",
                "ephemeral",
                "embed"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
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
          "req": true,
          "type": "`$INTEGER`"
        },
        {
          "name": "dailyUsed",
          "req": true,
          "type": "`$INTEGER`"
        },
        {
          "name": "key",
          "req": true,
          "type": "`$STRING`"
        },
        {
          "name": "resetsAt",
          "req": true,
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
              "parts": [
                "v1",
                "ephemeral",
                "key"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
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
          "type": "`$OBJECT`"
        },
        {
          "name": "executionProvider",
          "type": "`$STRING`"
        },
        {
          "name": "modelCard",
          "type": "`$OBJECT`"
        },
        {
          "name": "modelType",
          "req": true,
          "type": "`$STRING`"
        },
        {
          "name": "name",
          "req": true,
          "type": "`$STRING`"
        },
        {
          "name": "sequenceLen",
          "type": "`$INTEGER`"
        },
        {
          "name": "sourceDim",
          "type": "`$INTEGER`"
        },
        {
          "name": "sourceModel",
          "type": "`$STRING`"
        },
        {
          "name": "targetDim",
          "req": true,
          "type": "`$INTEGER`"
        },
        {
          "name": "targetModel",
          "req": true,
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
              "parts": [
                "v1",
                "models"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body.data`"
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


const config = new Config()

module.exports = {
  config
}

