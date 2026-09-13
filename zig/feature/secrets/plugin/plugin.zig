// VENDORED: @voxgig/plugin sdk-20260908-1556-0 (zig/src/plugin.zig)
// Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! THE ROOT A CONSUMER IMPORTS.
//!
//! Zig restricts a module's imports to the directory of its root source
//! file, so a host that takes this port as a named module
//! (`--dep plugin ... -Mplugin=<checkout>/zig/src/plugin.zig`) reaches
//! every file in `src/` through this one and through nothing else. The
//! test driver in `../test/` imports the files directly, because it
//! lives beside them; a consumer cannot, and this is what it gets
//! instead — the same role `index.ts` plays for the typescript port.
//!
//! EVERY MODULE, not the handful the first host happened to need: the
//! canonical surface is the whole of it (AGENTS.md, api parity), and a
//! root that exposed part of it would make the rest unreachable by
//! construction. A new file under `src/` is one line here.

pub const value = @import("value.zig");
pub const types = @import("types.zig");
pub const ref = @import("ref.zig");
pub const version = @import("version.zig");
pub const capability = @import("capability.zig");
pub const resolve = @import("resolve.zig");
pub const env = @import("env.zig");
pub const config = @import("config.zig");
pub const graph = @import("graph.zig");
pub const depend = @import("depend.zig");
pub const order = @import("order.zig");
pub const point = @import("point.zig");
pub const @"export" = @import("export.zig");
pub const catalog = @import("catalog.zig");
pub const inst = @import("inst.zig");
pub const host = @import("host.zig");
