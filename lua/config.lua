-- Univec SDK configuration

-- Build a fresh, fully materialised config table. Every call rebuilds the
-- whole structure, so prefer require("config_shared") unless you need a
-- private copy you intend to mutate.
local function make_config()
  return {
    main = {
      name = "Univec",
      slug = "univec",
      version = "0.0.1",
      target = "lua",
    },
    feature = {
      ["test"] = {
        ["options"] = {
          ["active"] = false,
        },
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
