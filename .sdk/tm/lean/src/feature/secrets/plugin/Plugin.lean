-- VENDORED: @voxgig/plugin sdk-20260908-1556-0 (lean/src/Plugin.lean)
-- Source: https://github.com/voxgig/plugin @ 48392f5e2b6d1434ee9b1a4a9a11f4480aaeb46a  [tag: sdk-20260908-1556-0]
-- License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
import Plugin.Value
import Plugin.Types
import Plugin.Ref
import Plugin.Version
import Plugin.Capability
import Plugin.Resolve
import Plugin.Env
import Plugin.Config
import Plugin.Graph
import Plugin.Order
import Plugin.Export
import Plugin.Depend
import Plugin.Defs
import Plugin.Host
import Plugin.Machine

/-!
# voxgig/plugin — the library root

Importing this compiles every module, which is the point: `lake` builds
only what a target's import graph reaches, and a module nothing imports
reports no errors because it is never compiled. Both libraries are
`@[default_target]` in `lakefile.lean` for the same reason.
-/
