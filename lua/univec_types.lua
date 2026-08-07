-- Typed models for the Univec SDK (LuaLS annotations).
--
-- GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
-- params (op.<name>.points[].args.params[]). Field/param types come from the
-- canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
-- @voxgig/apidef VALID_CANON). Annotations only — no runtime effect. Do not
-- edit by hand.

---@class Convert
---@field bridge_model string
---@field data table
---@field embedding table
---@field source_model string
---@field success boolean
---@field target_model string
---@field text table

---@class ConvertCreateData
---@field bridge_model string
---@field data table
---@field embedding table
---@field source_model string
---@field success boolean
---@field target_model string
---@field text table

---@class Embed
---@field data table
---@field model string
---@field success boolean
---@field text table

---@class EmbedCreateData
---@field data table
---@field model string
---@field success boolean
---@field text table

---@class EphemeralKey
---@field data table
---@field success boolean

---@class EphemeralKeyCreateData
---@field data table
---@field success boolean

---@class Model
---@field eval? table
---@field execution_provider? string
---@field model_card? table
---@field model_type string
---@field name string
---@field sequence_len? number
---@field source_dim? number
---@field source_model? string
---@field target_dim number
---@field target_model string

---@class ModelListMatch
---@field eval? table
---@field execution_provider? string
---@field model_card? table
---@field model_type? string
---@field name? string
---@field sequence_len? number
---@field source_dim? number
---@field source_model? string
---@field target_dim? number
---@field target_model? string

local M = {}

return M
