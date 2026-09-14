-- Univec SDK feature plugin definitions
--
-- The sekreto plugin DEFINITIONS the model selected per feature, required
-- below from the modules the catalogue's active `plugin.def` entries
-- declare. Handed to each feature (secrets builds its Sekreto with them):
-- a provider kind not listed here is unknown to this SDK - the four
-- built-in kinds (env, memory, dotenv, file) come with the core and never
-- appear here.

local plugin_boru = require("feature.secrets.sekreto.plugins.boru")
local plugin_hashicorp = require("feature.secrets.sekreto.plugins.hashicorp")


local FEATURE_PLUGINS = {
  ["secrets"] = {
    plugin_boru.boru,
    plugin_hashicorp.hashicorp,
  },
}


-- The definitions list for one feature's chain; empty when the model
-- selected no plugin group for it.
return function(name)
  return FEATURE_PLUGINS[name] or {}
end
