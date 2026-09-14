// The plugin definitions the model selected for the `secrets`
// feature (generated - see Config_zig FeaturePlugins). The ROOT of the
// `sekretoplugins` build module: zig analyses only what a module root
// reaches, so a kind this file does not name is neither in the provider
// vocabulary nor compiled - this file IS the plugin trim.
//
// Upstream sekreto's contract since its registry was retired: a provider
// kind not handed to the constructor is unknown to that Sekreto.

const sekreto = @import("sekreto");

// The shared HTTP round-trip the vault kinds import by relative path, and
// the exchange's fetch of last resort (feature/secrets.zig). In NO
// plugin group, so it is always reachable from here - which is what
// upstream's own all.zig does.
pub const httpjson = @import("plugins/httpjson.zig");

pub const boru = @import("plugins/boru.zig").boru;
pub const hashicorp = @import("plugins/hashicorp.zig").hashicorp;

pub const SELECTED = [_]sekreto.Definition{
    boru,
    hashicorp,
};
