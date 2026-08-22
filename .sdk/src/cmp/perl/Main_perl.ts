
import * as Path from 'node:path'

import {
  cmp, each, names,
  File, Content, Copy, Folder, Fragment,
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
  const feature = getModelPath(model, `main.${KIT}.feature`)

  Package({ target })

  Gitignore({})

  // Copy tm/perl files with replacements
  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//],
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
