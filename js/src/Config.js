
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
          "active": true,
          "name": "bridge_model",
          "req": true,
          "type": "`$STRING`",
          "index$": 0
        },
        {
          "active": true,
          "name": "data",
          "req": true,
          "type": "`$OBJECT`",
          "index$": 1
        },
        {
          "active": true,
          "name": "embedding",
          "req": true,
          "type": "`$ARRAY`",
          "index$": 2
        },
        {
          "active": true,
          "name": "source_model",
          "req": true,
          "type": "`$STRING`",
          "index$": 3
        },
        {
          "active": true,
          "name": "success",
          "req": true,
          "type": "`$BOOLEAN`",
          "index$": 4
        },
        {
          "active": true,
          "name": "target_model",
          "req": true,
          "type": "`$STRING`",
          "index$": 5
        },
        {
          "active": true,
          "name": "text",
          "req": true,
          "type": "`$ARRAY`",
          "index$": 6
        }
      ],
      "name": "convert",
      "op": {
        "create": {
          "input": "data",
          "name": "create",
          "points": [
            {
              "active": true,
              "args": {},
              "method": "POST",
              "orig": "/v1/convert",
              "parts": [
                "v1",
                "convert"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body`"
              },
              "index$": 0
            },
            {
              "active": true,
              "args": {},
              "method": "POST",
              "orig": "/v1/embed-bridge",
              "parts": [
                "v1",
                "embed-bridge"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body`"
              },
              "index$": 1
            },
            {
              "active": true,
              "args": {},
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
                "res": "`body`"
              },
              "index$": 2
            },
            {
              "active": true,
              "args": {},
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
                "res": "`body`"
              },
              "index$": 3
            }
          ],
          "key$": "create"
        }
      },
      "relations": {
        "ancestors": []
      }
    },
    "embed": {
      "fields": [
        {
          "active": true,
          "name": "data",
          "req": true,
          "type": "`$OBJECT`",
          "index$": 0
        },
        {
          "active": true,
          "name": "model",
          "req": true,
          "type": "`$STRING`",
          "index$": 1
        },
        {
          "active": true,
          "name": "success",
          "req": true,
          "type": "`$BOOLEAN`",
          "index$": 2
        },
        {
          "active": true,
          "name": "text",
          "req": true,
          "type": "`$ARRAY`",
          "index$": 3
        }
      ],
      "name": "embed",
      "op": {
        "create": {
          "input": "data",
          "name": "create",
          "points": [
            {
              "active": true,
              "args": {},
              "method": "POST",
              "orig": "/v1/embed",
              "parts": [
                "v1",
                "embed"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body`"
              },
              "index$": 0
            },
            {
              "active": true,
              "args": {},
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
                "res": "`body`"
              },
              "index$": 1
            }
          ],
          "key$": "create"
        }
      },
      "relations": {
        "ancestors": []
      }
    },
    "ephemeral_key": {
      "fields": [
        {
          "active": true,
          "name": "data",
          "req": true,
          "type": "`$OBJECT`",
          "index$": 0
        },
        {
          "active": true,
          "name": "success",
          "req": true,
          "type": "`$BOOLEAN`",
          "index$": 1
        }
      ],
      "name": "ephemeral_key",
      "op": {
        "create": {
          "input": "data",
          "name": "create",
          "points": [
            {
              "active": true,
              "args": {},
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
                "res": "`body`"
              },
              "index$": 0
            }
          ],
          "key$": "create"
        }
      },
      "relations": {
        "ancestors": []
      }
    },
    "model": {
      "fields": [
        {
          "active": true,
          "name": "eval",
          "req": false,
          "type": "`$OBJECT`",
          "index$": 0
        },
        {
          "active": true,
          "name": "execution_provider",
          "req": false,
          "type": "`$STRING`",
          "index$": 1
        },
        {
          "active": true,
          "name": "model_card",
          "req": false,
          "type": "`$OBJECT`",
          "index$": 2
        },
        {
          "active": true,
          "name": "model_type",
          "req": true,
          "type": "`$STRING`",
          "index$": 3
        },
        {
          "active": true,
          "name": "name",
          "req": true,
          "type": "`$STRING`",
          "index$": 4
        },
        {
          "active": true,
          "name": "sequence_len",
          "req": false,
          "type": "`$INTEGER`",
          "index$": 5
        },
        {
          "active": true,
          "name": "source_dim",
          "req": false,
          "type": "`$INTEGER`",
          "index$": 6
        },
        {
          "active": true,
          "name": "source_model",
          "req": false,
          "type": "`$STRING`",
          "index$": 7
        },
        {
          "active": true,
          "name": "target_dim",
          "req": true,
          "type": "`$INTEGER`",
          "index$": 8
        },
        {
          "active": true,
          "name": "target_model",
          "req": true,
          "type": "`$STRING`",
          "index$": 9
        }
      ],
      "name": "model",
      "op": {
        "list": {
          "input": "data",
          "name": "list",
          "points": [
            {
              "active": true,
              "args": {},
              "method": "GET",
              "orig": "/v1/models",
              "parts": [
                "v1",
                "models"
              ],
              "select": {},
              "transform": {
                "req": "`reqdata`",
                "res": "`body`"
              },
              "index$": 0
            }
          ],
          "key$": "list"
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

