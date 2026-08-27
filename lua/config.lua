-- Univec SDK configuration

-- Build a fresh, fully materialised config table. Every call rebuilds the
-- whole structure, so prefer require("config_shared") unless you need a
-- private copy you intend to mutate.
local function make_config()
  return {
    main = {
      name = "Univec",
      slug = "univec",
      version = "0.1.1",
      target = "lua",
    },
    feature = {
      ["audit"] = {
        ["options"] = {
          ["active"] = false,
          ["actor"] = "anonymous",
          ["max"] = 1000,
        },
        ["transport"] = "none",
      },
      ["cache"] = {
        ["options"] = {
          ["active"] = false,
          ["max"] = 256,
          ["methods"] = {
            "GET",
          },
          ["ttl"] = 5000,
        },
        ["transport"] = "wrap",
      },
      ["clienttrack"] = {
        ["options"] = {
          ["active"] = false,
          ["clientVersion"] = "0.0.1",
        },
        ["transport"] = "none",
      },
      ["cost"] = {
        ["options"] = {
          ["active"] = false,
          ["budget"] = 0,
          ["currency"] = "USD",
          ["header"] = "",
          ["onBudget"] = "warn",
          ["path"] = "",
          ["perUnit"] = 0,
          ["rates"] = {},
          ["unit"] = 0,
        },
        ["transport"] = "wrap",
      },
      ["debug"] = {
        ["options"] = {
          ["active"] = false,
          ["max"] = 100,
          ["redact"] = {
            "authorization",
            "cookie",
            "set-cookie",
            "api-key",
            "apikey",
            "x-api-key",
            "idempotency-key",
          },
        },
        ["transport"] = "none",
      },
      ["idempotency"] = {
        ["options"] = {
          ["active"] = false,
          ["header"] = "Idempotency-Key",
          ["methods"] = {
            "POST",
            "PUT",
            "PATCH",
            "DELETE",
          },
          ["ops"] = {
            "create",
            "update",
            "remove",
          },
        },
        ["transport"] = "none",
      },
      ["log"] = {
        ["options"] = {
          ["active"] = true,
        },
        ["transport"] = "none",
      },
      ["metrics"] = {
        ["options"] = {
          ["active"] = false,
        },
        ["transport"] = "none",
      },
      ["netsim"] = {
        ["options"] = {
          ["active"] = false,
          ["errorTimes"] = 0,
          ["failEvery"] = 0,
          ["failRate"] = 0,
          ["failStatus"] = 503,
          ["failTimes"] = 0,
          ["latency"] = 0,
          ["offline"] = false,
          ["rateLimitTimes"] = 0,
          ["retryAfter"] = 0,
          ["seed"] = 1,
        },
        ["transport"] = "wrap",
      },
      ["paging"] = {
        ["options"] = {
          ["active"] = false,
          ["afterVar"] = "after",
          ["cursorParam"] = "cursor",
          ["firstVar"] = "first",
          ["limitParam"] = "limit",
          ["pageParam"] = "page",
          ["startPage"] = 1,
        },
        ["transport"] = "none",
      },
      ["proxy"] = {
        ["options"] = {
          ["active"] = false,
          ["fromEnv"] = false,
          ["noProxy"] = {},
          ["url"] = "",
        },
        ["transport"] = "wrap",
      },
      ["ratelimit"] = {
        ["options"] = {
          ["active"] = false,
          ["burst"] = 5,
          ["rate"] = 5,
        },
        ["transport"] = "wrap",
      },
      ["rbac"] = {
        ["options"] = {
          ["active"] = false,
          ["deny"] = false,
          ["permissions"] = {},
          ["rules"] = {},
        },
        ["transport"] = "none",
      },
      ["retry"] = {
        ["options"] = {
          ["active"] = false,
          ["factor"] = 2,
          ["maxDelay"] = 2000,
          ["minDelay"] = 50,
          ["retries"] = 2,
          ["statuses"] = {
            408,
            425,
            429,
            500,
            502,
            503,
            504,
          },
        },
        ["transport"] = "wrap",
      },
      ["streaming"] = {
        ["options"] = {
          ["active"] = false,
          ["chunkDelay"] = 0,
          ["chunkSize"] = 0,
        },
        ["transport"] = "none",
      },
      ["telemetry"] = {
        ["options"] = {
          ["active"] = false,
        },
        ["transport"] = "none",
      },
      ["test"] = {
        ["options"] = {
          ["active"] = false,
        },
        ["transport"] = "base",
      },
      ["timeout"] = {
        ["options"] = {
          ["active"] = false,
          ["ms"] = 30000,
        },
        ["transport"] = "wrap",
      },
    },
    options = {
      base = "https://api.univec.ai",
      auth = {
        prefix = "Bearer",
      },
      headers = {
        ["content-type"] = "application/json",
      },
      entity = {
        ["convert"] = {},
        ["embed"] = {},
        ["ephemeral_key"] = {},
        ["model"] = {},
      },
    },
    entity = {
      ["convert"] = {
        ["fields"] = {
          {
            ["name"] = "bridge_model",
            ["req"] = true,
            ["short"] = "Embed model used to vectorise the text before translation.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "embeddings",
            ["req"] = true,
            ["short"] = "Translated vectors, in the target model's dimension.",
            ["type"] = "`$ARRAY`",
          },
          {
            ["name"] = "source_model",
            ["req"] = true,
            ["short"] = "Model space the supplied vectors are currently in.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "target_model",
            ["req"] = true,
            ["short"] = "Model space to translate into.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "texts",
            ["req"] = true,
            ["short"] = "Texts to embed and translate.",
            ["type"] = "`$ARRAY`",
          },
        },
        ["name"] = "convert",
        ["op"] = {
          ["create"] = {
            ["input"] = "data",
            ["name"] = "create",
            ["points"] = {
              {
                ["args"] = {},
                ["kind"] = "http",
                ["method"] = "POST",
                ["orig"] = "/v1/convert",
                ["parts"] = {
                  "v1",
                  "convert",
                },
                ["select"] = {},
                ["transform"] = {
                  ["req"] = "`reqdata`",
                  ["res"] = "`body.data`",
                },
              },
              {
                ["args"] = {},
                ["kind"] = "http",
                ["method"] = "POST",
                ["orig"] = "/v1/embed-bridge",
                ["parts"] = {
                  "v1",
                  "embed-bridge",
                },
                ["select"] = {},
                ["transform"] = {
                  ["req"] = "`reqdata`",
                  ["res"] = "`body.data`",
                },
              },
              {
                ["args"] = {},
                ["kind"] = "http",
                ["method"] = "POST",
                ["orig"] = "/v1/ephemeral/convert",
                ["parts"] = {
                  "v1",
                  "ephemeral",
                  "convert",
                },
                ["select"] = {},
                ["transform"] = {
                  ["req"] = "`reqdata`",
                  ["res"] = "`body.data`",
                },
              },
              {
                ["args"] = {},
                ["kind"] = "http",
                ["method"] = "POST",
                ["orig"] = "/v1/ephemeral/embed-bridge",
                ["parts"] = {
                  "v1",
                  "ephemeral",
                  "embed-bridge",
                },
                ["select"] = {},
                ["transform"] = {
                  ["req"] = "`reqdata`",
                  ["res"] = "`body.data`",
                },
              },
            },
          },
        },
        ["relations"] = {
          ["ancestors"] = {},
        },
      },
      ["embed"] = {
        ["fields"] = {
          {
            ["name"] = "embeddings",
            ["req"] = true,
            ["short"] = "One vector per input text, in input order.",
            ["type"] = "`$ARRAY`",
          },
          {
            ["name"] = "model",
            ["req"] = true,
            ["short"] = "Model that produced the vectors.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "texts",
            ["req"] = true,
            ["short"] = "Texts to embed.",
            ["type"] = "`$ARRAY`",
          },
        },
        ["name"] = "embed",
        ["op"] = {
          ["create"] = {
            ["input"] = "data",
            ["name"] = "create",
            ["points"] = {
              {
                ["args"] = {},
                ["kind"] = "http",
                ["method"] = "POST",
                ["orig"] = "/v1/embed",
                ["parts"] = {
                  "v1",
                  "embed",
                },
                ["select"] = {},
                ["transform"] = {
                  ["req"] = "`reqdata`",
                  ["res"] = "`body.data`",
                },
              },
              {
                ["args"] = {},
                ["kind"] = "http",
                ["method"] = "POST",
                ["orig"] = "/v1/ephemeral/embed",
                ["parts"] = {
                  "v1",
                  "ephemeral",
                  "embed",
                },
                ["select"] = {},
                ["transform"] = {
                  ["req"] = "`reqdata`",
                  ["res"] = "`body.data`",
                },
              },
            },
          },
        },
        ["relations"] = {
          ["ancestors"] = {},
        },
      },
      ["ephemeral_key"] = {
        ["fields"] = {
          {
            ["name"] = "dailyLimit",
            ["req"] = true,
            ["short"] = "Calls permitted per day.",
            ["type"] = "`$INTEGER`",
          },
          {
            ["name"] = "dailyUsed",
            ["req"] = true,
            ["short"] = "Calls already used today.",
            ["type"] = "`$INTEGER`",
          },
          {
            ["name"] = "key",
            ["req"] = true,
            ["short"] = "The ephemeral API key, prefixed `eph_`.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "resetsAt",
            ["req"] = true,
            ["short"] = "When the daily allowance resets.",
            ["type"] = "`$STRING`",
          },
        },
        ["name"] = "ephemeral_key",
        ["op"] = {
          ["create"] = {
            ["input"] = "data",
            ["name"] = "create",
            ["points"] = {
              {
                ["args"] = {},
                ["kind"] = "http",
                ["method"] = "POST",
                ["orig"] = "/v1/ephemeral/key",
                ["parts"] = {
                  "v1",
                  "ephemeral",
                  "key",
                },
                ["select"] = {},
                ["transform"] = {
                  ["req"] = "`reqdata`",
                  ["res"] = "`body.data`",
                },
              },
            },
          },
        },
        ["relations"] = {
          ["ancestors"] = {},
        },
      },
      ["model"] = {
        ["fields"] = {
          {
            ["name"] = "eval",
            ["short"] = "Retrieval-fidelity metrics for a convert model.",
            ["type"] = "`$OBJECT`",
          },
          {
            ["name"] = "executionProvider",
            ["short"] = "Hardware backend, e.g.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "modelCard",
            ["short"] = "Convert models only: training provenance and architecture detail.",
            ["type"] = "`$OBJECT`",
          },
          {
            ["name"] = "modelType",
            ["req"] = true,
            ["short"] = "`embed` for text-to-vector models, `convert` for space-translation models.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "name",
            ["req"] = true,
            ["short"] = "Model identifier used in requests.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "sequenceLen",
            ["short"] = "Embed models only: maximum input sequence length.",
            ["type"] = "`$INTEGER`",
          },
          {
            ["name"] = "sourceDim",
            ["short"] = "Convert models only: source vector dimension.",
            ["type"] = "`$INTEGER`",
          },
          {
            ["name"] = "sourceModel",
            ["short"] = "Convert models only: the source model space.",
            ["type"] = "`$STRING`",
          },
          {
            ["name"] = "targetDim",
            ["req"] = true,
            ["short"] = "Dimension of the produced vectors.",
            ["type"] = "`$INTEGER`",
          },
          {
            ["name"] = "targetModel",
            ["req"] = true,
            ["short"] = "The model space produced.",
            ["type"] = "`$STRING`",
          },
        },
        ["name"] = "model",
        ["op"] = {
          ["list"] = {
            ["input"] = "data",
            ["name"] = "list",
            ["points"] = {
              {
                ["args"] = {},
                ["kind"] = "http",
                ["method"] = "GET",
                ["orig"] = "/v1/models",
                ["parts"] = {
                  "v1",
                  "models",
                },
                ["select"] = {},
                ["transform"] = {
                  ["req"] = "`reqdata`",
                  ["res"] = "`body.data`",
                },
              },
            },
          },
        },
        ["relations"] = {
          ["ancestors"] = {},
        },
      },
    },
  }
end


local function make_feature(name)
  local features = require("features")
  local factory = features[name]
  if factory ~= nil then
    return factory()
  end
  return features.base()
end


-- Attach make_feature to the SDK class
local function setup_sdk(SDK)
  SDK._make_feature = make_feature
end


return make_config
