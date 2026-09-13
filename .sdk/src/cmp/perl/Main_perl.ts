
import * as Path from 'node:path'

import {
  cmp, each, names,
  File, Content, Copy, Folder, Fragment,
  pluginExcludes,
  targetFeatures,
  TEST_CONTROL_EXCLUDE
} from '@voxgig/sdkgen'


import type {
  ModelEntity
} from '@voxgig/apidef'


import {
  KIT,
  getModelPath
} from '@voxgig/apidef'


import { Package } from './Package_perl'
import { Config } from './Config_perl'
import { Gitignore } from './Gitignore_perl'
import { MainEntity } from './MainEntity_perl'


// Feature class name: 'retry' -> 'Retry' (matches feature/*_feature.pm).
function featureClassPart(name: string): string {
  return name.charAt(0).toUpperCase() + name.slice(1)
}


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  // Does the secrets feature apply here and is it switched on? Both, since
  // targetFeatures already dropped it for a target with no sekreto port.
  const secrets = null != (feature as any).secrets

  Package({ target })

  Gitignore({})

  // Copy tm/perl files with replacements
  Copy({
    from: 'tm/' + target.name,
    // An ACTIVE feature's INACTIVE plugins do not ship. perl has no
    // src/feature layout (srcfeature: false), so this blanket copy is the
    // one place the generate-time plugin trim can act; the model's
    // `plugin.<group>.path` entries name their files relative to THIS
    // copy's root ('feature/secrets/plugins/Voxgig/Sekreto/Plugins/
    // <Kind>.pm'). See helpers/featureSource.pluginExcludes, and
    // Main_go.ts / Main_py.ts, which do the same.
    exclude: [/src\//, TEST_CONTROL_EXCLUDE, ...pluginExcludes(model)],
    replace: {
      ...props.ctx$.stdrep,
    }
  })

  // Generate main SDK module: lib/<Name>SDK.pm (package <Name>SDK), so
  // callers write `use lib '<sdk>/lib'; use <Name>SDK;`.
  Folder({ name: 'lib' }, () => {
    File({ name: model.const.Name + 'SDK.pm' }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/perl/fragment/Main.fragment.pm'),
          replace: {
            ...props.ctx$.stdrep,

            // Feature-hook markers (jostraca's built-in `#Name-Hook` pattern
            // only matches `//` comments; perl uses `#`).
            '/(?<indent>[ \\t]*)#[ \\t]*#(?<name>[A-Za-z0-9]+)-Hook[ \\t]*\\n?/':
              ({ name, indent }: any) =>
                `${indent}$utility->{feature_hook}->($ctx, "${name}");\n`,

            // SECRETS. The accessor is emitted only when the secrets
            // feature applies to this target AND the model activates it -
            // with the feature off the marker line is REMOVED, so the
            // inactive output is byte-identical to pre-migration.
            //
            // The LIVE Sekreto, not a clone: sekreto holds provider and
            // cache state, so a clone would resolve into a copy nothing
            // else can see.
            //
            // There is deliberately NO resolve seam here. Unlike ts and
            // py, this port resolves at the TRANSPORT (see
            // feature/secrets_feature.pm), which every wire path -
            // entity ops, direct() and graphql() - already crosses.
            '/(?<indent>[ \\t]*)#[ \\t]*#SecretsAccessor[ \\t]*\\n?/':
              ({ indent }: any) => !secrets ? '' :
                `${indent}# The LIVE Sekreto instance: for arbitrary secrets and redaction.\n` +
                `${indent}#\n` +
                `${indent}#   $sdk->secrets->get('db.password')\n` +
                `${indent}#   $sdk->secrets->redactall($logline)\n` +
                `${indent}#\n` +
                `${indent}# Never a clone: sekreto holds provider state (caches, vault\n` +
                `${indent}# leases) that has to stay live to be worth anything.\n` +
                `${indent}sub secrets {\n` +
                `${indent}  my ($self) = @_;\n` +
                `${indent}  my $f = $self->{_secrets};\n` +
                `${indent}  return defined $f ? $f->sekreto : undef;\n` +
                `${indent}}\n\n`,
          }
        },

        // Entities - injected at SLOT
        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK }
            MainEntity(entprops)
          })
        })
    })
  })

  // Generate config module
  Folder({ name: '.' }, () => {
    Config({ target })
  })

  // Generate feature factory module
  File({ name: 'features.pm' }, () => {
    Content(`# ${model.const.Name} SDK feature factory

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/feature/base_feature.pm"));
`)

    each(feature, (feat: any) => {
      if (feat.name !== 'base') {
        Content(`require(Cwd::abs_path("$__dir/feature/${feat.name}_feature.pm"));
`)
      }
    })

    Content(`
package ${model.const.Name}Features;

sub make_feature {
  my ($name) = @_;
  $name = '' unless defined $name;
  return ${model.const.Name}BaseFeature->new if 'base' eq $name;
`)

    each(feature, (feat: any) => {
      if (feat.name !== 'base') {
        const fname = featureClassPart(feat.name)
        Content(`  return ${model.const.Name}${fname}Feature->new if '${feat.name}' eq $name;
`)
      }
    })

    Content(`  return ${model.const.Name}BaseFeature->new;
}

1;
`)
  })

})


export {
  Main
}
