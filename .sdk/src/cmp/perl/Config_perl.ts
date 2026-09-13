
import {
  Content,
  File,
  cmp,
  configDefinition,
  each,
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


// PLUGIN DEFINITION IMPORTS AND THE FEATURE_PLUGINS TABLE (the perl peer
// of cmp/py/Config_py.ts pluginImports/pluginDefs and cmp/go's
// featurePlugins).
//
// Upstream sekreto replaced its self-registration registry with
// voxgig/plugin definitions: a provider kind the caller did not pass in
// via `plugins => [...]` is unknown to that Sekreto. So config imports
// each active plugin's exported definition BY NAME (the model's
// `def.perl` map) and hands the list to the feature through
// FEATURE_PLUGINS.
//
// The `def` map is declared in the model rather than derived from
// filenames because one module may export several definitions (sekreto's
// Aws.pm exports awssecrets AND awsparams). A def value is the module's
// path under tm/perl ('feature/secrets/plugins/Voxgig/Sekreto/Plugins/
// Hashicorp.pm'); the vendored tree keeps upstream's PACKAGE layout, so
// the module NAME is that path with the vendor root and the extension
// removed and the separators turned into '::'.
const PLUGIN_ROOT = 'feature/secrets/plugins/'


function pluginModule(path: string): string {
  return String(path)
    .replace(new RegExp('^' + PLUGIN_ROOT), '')
    .replace(/\.pm$/, '')
    .replace(/\//g, '::')
}


// path -> [symbol, ...] for every ACTIVE plugin of every feature, so one
// `use` line serves a two-definition module.
function pluginsByPath(feature: any): Record<string, Record<string, string[]>> {
  const out: Record<string, Record<string, string[]>> = {}

  each(feature, (f: any) => {
    const bypath: Record<string, string[]> = {}

    each(f.plugin, (plugin: any) => {
      // Filter on `active` HERE rather than trusting the feature object to
      // arrive filtered: getting it wrong in this direction emits a `use`
      // for a module the plugin trim just deleted - an SDK that does not
      // LOAD, rather than one that merely carries too much. Config_py.ts
      // records the same rule.
      if (false === plugin.active || null == plugin.active) return

      for (const [sym, one] of Object.entries(plugin.def?.perl || {})) {
        const path = String(one)
        ;(bypath[path] = bypath[path] || []).push(sym)
      }
    })

    if (0 < Object.keys(bypath).length) {
      out[f.name] = bypath
    }
  })

  return out
}


// The config is emitted as a JSON heredoc parsed at load time by the
// vendored struct utility (Voxgig::Struct::parse_json). This keeps
// booleans/nulls faithful (Perl has no native boolean scalar) and yields
// insertion-ordered maps - and stays N-feature-safe: any number of
// features simply serialize into the "feature" block.
const Config = cmp(async function Config(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  // THE canonical config object, from the shared helper - this component
  // used to hand-assemble its own (and had already drifted: no server
  // block, no identity beyond main.name). Passing the target name opts
  // in to the main slug/version/target identity fields (station
  // descriptor inputs), matching the ts/js/rb targets.
  const { def: configDef } = configDefinition(model, target.name)

  const configJson = JSON.stringify(configDef, null, 2)

  // Gated by the applicability tags, so this target never imports a
  // plugin definition it has no source for. One rule, one place:
  // helpers/applicability.
  const bypath = pluginsByPath(targetFeatures(model, target))
  const features = Object.keys(bypath).sort()

  // Every emitted line below is conditional on there being at least one
  // active plugin definition: an SDK that selected no plugin group (or no
  // secrets feature at all) gets exactly the config.pm it got before.
  const vendorInc = 0 === features.length ? '' : `
# The vendored sekreto and plugin ports keep their UPSTREAM package layout,
# so they resolve through @INC rather than a file-path require - the same
# convention feature/secrets_feature.pm and t/omni.pm use. This BEGIN runs
# before the 'use' lines below, which are compile-time.
BEGIN {
  unshift @INC,
    "$__dir/feature/secrets/sekreto",
    "$__dir/feature/secrets/plugin",
    "$__dir/feature/secrets/plugins";
}
`

  let pluginUse = ''
  let pluginTable = ''

  if (0 < features.length) {
    const lines: string[] = []
    for (const fname of features) {
      for (const path of Object.keys(bypath[fname]).sort()) {
        const syms = Array.from(new Set(bypath[fname][path])).sort()
        lines.push(`use ${pluginModule(path)} qw(${syms.join(' ')});`)
      }
    }
    // A module shared by two features is imported once.
    pluginUse = '\n' + Array.from(new Set(lines)).join('\n') + '\n'

    const entries = features.map((fname) => {
      const syms = Array.from(new Set(
        Object.values(bypath[fname]).reduce(
          (a: string[], b: string[]) => a.concat(b), []))).sort()
      return `  '${fname}' => [ ${syms.map((s) => s + '()').join(', ')} ],`
    })

    pluginTable = `
# THE SDK'S PROVIDER VOCABULARY, from the model's active plugin groups.
#
# sekreto's core ships four built-in kinds (env, memory, dotenv, file) and
# nothing else: a kind not passed in here is UNKNOWN to that Sekreto. So
# this table is what decides which vault, cloud, SaaS or CLI providers a
# chain in this SDK may name - and an inactive group is not merely
# unimported, its module is not generated at all.
our %FEATURE_PLUGINS = (
${entries.join('\n')}
);

sub feature_plugins {
  my ($name) = @_;
  $name = '' unless defined $name;
  my $list = $FEATURE_PLUGINS{$name};
  return defined $list ? $list : [];
}
`
  }

  File({ name: 'config.pm' }, () => {

    Content(`# ${model.const.Name} SDK configuration

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
${vendorInc}require(Cwd::abs_path("$__dir/lib/Voxgig/Struct.pm"));

package ${model.const.Name}Config;
${pluginUse}
# GENERATED from the API model - do not edit by hand. Parsed fresh on
# each call so callers can safely mutate their copy.
my $CONFIG_JSON = <<'END_CONFIG_JSON';
${configJson}
END_CONFIG_JSON

sub make_config {
  return Voxgig::Struct::parse_json($CONFIG_JSON);
}

# SHARED CONFIG (sdkgen rung L2).
#
# The SDK reads the config on every request and never writes to it, so one
# instance is shared by every client rather than rebuilt per client - the
# difference between parsing the embedded JSON once and once per client.
#
# The returned structure is SHARED: treat it as read-only. Callers that need to
# mutate should use make_config, which always parses a fresh copy.
my $SHARED_CONFIG;

sub shared_config {
  $SHARED_CONFIG = make_config() unless defined $SHARED_CONFIG;
  return $SHARED_CONFIG;
}

sub make_feature {
  my ($name) = @_;
  require(Cwd::abs_path("$__dir/features.pm"));
  return ${model.const.Name}Features::make_feature($name);
}
${pluginTable}
1;
`)
  })
})


export {
  Config
}
