-- Typed models for the Univec SDK (LuaLS annotations).
--
-- GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
-- params (op.<name>.points[].args.params[]). Field/param types come from the
-- canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
-- @voxgig/apidef VALID_CANON). Annotations only — no runtime effect. Do not
-- edit by hand.

---@class Convert
---@field embeddings table
---@field source_model string
---@field target_model string

---@class ConvertCreateData
---@field embeddings table
---@field source_model string
---@field target_model string

---@class Embed
---@field embeddings table
---@field model string
---@field texts table

---@class EmbedCreateData
---@field embeddings table
---@field model string
---@field texts table

---@class EphemeralKey
---@field dailyLimit number
---@field dailyUsed number
---@field key string
---@field resetsAt string

---@class EphemeralKeyCreateData
---@field dailyLimit number
---@field dailyUsed number
---@field key string
---@field resetsAt string

---@class Model
---@field eval? table
---@field executionProvider? string
---@field modelCard? table
---@field modelType string
---@field name string
---@field sequenceLen? number
---@field sourceDim? number
---@field sourceModel? string
---@field targetDim number
---@field targetModel string

---@class ModelListMatch
---@field eval? table
---@field executionProvider? string
---@field modelCard? table
---@field modelType? string
---@field name? string
---@field sequenceLen? number
---@field sourceDim? number
---@field sourceModel? string
---@field targetDim? number
---@field targetModel? string

local M = {}

return M
