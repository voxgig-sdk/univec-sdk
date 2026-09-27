import {
  Content,
  File,
  cmp,
  entitySpecMap,
  optionSpec,
} from '@voxgig/sdkgen'


import {
  Model,
} from '@voxgig/apidef'


const Schema = cmp(async function Schema(props: any) {
  const ctx$ = props.ctx$
  const target = props.target

  const model: Model = ctx$.model

  const optspec = optionSpec(model, target.name)
  const entityspec = entitySpecMap(model, target.name) || {}

  // Beside config.pm, and for the same reason: the generated data sits at the
  // SDK root, so nothing under utility/ or feature/ has to reach up for it.
  File({ name: 'schema.pm' }, () => {

    Content(`# ${model.const.Name} SDK: generated schemas. Do not edit.
#
# Built from the model: \`main.kit.optspec\` and each feature's
# \`config.options\` for the option spec; entity \`fields{}.type\` for the
# entity specs.

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/lib/Voxgig/Struct.pm"));

package ${model.const.Name}Schema;

my $OPTSPEC_JSON = <<'END_OPTSPEC_JSON';
${JSON.stringify(optspec, null, 2)}
END_OPTSPEC_JSON

my $ENTITYSPEC_JSON = <<'END_ENTITYSPEC_JSON';
${JSON.stringify(entityspec, null, 2)}
END_ENTITYSPEC_JSON

sub make_optspec {
  return Voxgig::Struct::parse_json($OPTSPEC_JSON);
}

sub make_entityspec {
  return Voxgig::Struct::parse_json($ENTITYSPEC_JSON);
}

# SHARED SPECS, the shape ${model.const.Name}Config::shared_config uses and for
# the same reasons: the spec is read on every client construction and never
# mutated, so a per-call parse would be pure waste.
#
# The returned structures are SHARED: treat them as read-only. make_options
# validates AGAINST the spec and writes into the options, never into the spec.
my $SHARED_OPTSPEC;
my $SHARED_ENTITYSPEC;

sub optspec {
  $SHARED_OPTSPEC = make_optspec() unless defined $SHARED_OPTSPEC;
  return $SHARED_OPTSPEC;
}

sub entityspec {
  $SHARED_ENTITYSPEC = make_entityspec() unless defined $SHARED_ENTITYSPEC;
  return $SHARED_ENTITYSPEC;
}

1;
`)
  })
})


export {
  Schema
}
