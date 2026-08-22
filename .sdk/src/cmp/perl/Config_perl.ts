
import {
  Content,
  File,
  cmp,
  configDefinition,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


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

  File({ name: 'config.pm' }, () => {

    Content(`# ${model.const.Name} SDK configuration

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/lib/Voxgig/Struct.pm"));

package ${model.const.Name}Config;

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

1;
`)
  })
})


export {
  Config
}
