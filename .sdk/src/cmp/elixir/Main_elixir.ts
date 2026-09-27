
import * as Path from 'node:path'

import {
  cmp, each,
  File, Folder, Content, Copy, Fragment,
  pluginExcludes,
  targetFeatures,
} from '@voxgig/sdkgen'


import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


import { Package } from './Package_elixir'
import { Config } from './Config_elixir'
import { Schema } from './Schema_elixir'
import { PrepareAuth } from './PrepareAuth_elixir'
import { Gitignore } from './Gitignore_elixir'
import { MainEntity } from './MainEntity_elixir'
import { EntityTypes } from './EntityTypes_elixir'


const HOOK_KEY =
  '/(?<indent>[ \\t]*)#[ \\t]*#(?<name>[A-Za-z0-9]+)-Hook[ \\t]*\\n?/'


function cap(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1)
}


const Main = cmp(async function Main(props: any) {
  const { target } = props
  const { model, stdrep } = props.ctx$

  const Name = model.const.Name
  const entity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const ff = Path.normalize(__dirname + '/../../../src/cmp/elixir/fragment/')

  Package({ target })
  Gitignore({})

  // Generate the documented typespec module (lib/<app>_types.ex).
  EntityTypes({ target })

  Copy({
    from: 'tm/' + target.name,
    exclude: [/src\//, /lib\/projectname\//],
    replace: {
      ...stdrep,
    }
  })

  Folder({ name: 'lib' }, () => {
    Copy({
      from: 'tm/' + target.name + '/lib/projectname',
      to: model.const.name,
      exclude: [...pluginExcludes(model)],
      replace: {
        ...stdrep,
      }
    })
  })

  Folder({ name: 'lib' }, () => {

    // Main SDK module (entity factory fns injected at the slot).
    File({ name: model.const.name + '.' + target.ext }, () => {
      Fragment(
        {
          from: ff + 'Main.fragment.ex',
          replace: {
            ...stdrep,
            ProjectName: Name,
          }
        },
        () => {
          each(entity, (ent: any) => {
            MainEntity({ target, entity: ent })
          })
        }
      )
    })

    File({ name: 'pipeline.' + target.ext }, () => {
      Fragment({
        from: ff + 'Pipeline.fragment.ex',
        replace: {
          ...stdrep,
          ProjectName: Name,
          [HOOK_KEY]: ({ name, indent }: any) =>
            `${indent}Utility.feature_hook(ctx, "${name}")\n`,
        }
      })
    })

    // Feature factory.
    File({ name: 'features.' + target.ext }, () => {
      Content(`# ${Name} SDK feature factory

defmodule ${Name}.Features do
  def make_feature(name) do
    case name do
`)

      each(feature, (f: any) => {
        if (f.name === 'base') {
          Content(`      "base" -> ${Name}.Feature.new()
`)
        }
        else {
          Content(`      ${JSON.stringify(f.name)} -> ${Name}.Feature.${cap(f.name)}.new()
`)
        }
      })

      Content(`      _ -> ${Name}.Feature.new()
    end
  end
end
`)
    })

    PrepareAuth({ target })
  })

  // Config module.
  Config({ target })
  Schema({ target })
})


export {
  Main
}
