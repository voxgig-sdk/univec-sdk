
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
import { Gitignore } from './Gitignore_elixir'
import { MainEntity } from './MainEntity_elixir'
import { EntityTypes } from './EntityTypes_elixir'


// #`-comment hook marker key (gotcha #1: jostraca's built-in #Name-Tag
// replacement only matches `//` comments, so an Elixir `# #<Name>-Hook`
// line never matches and the pipeline hook would be silently dropped).
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

  // Copy tm/elixir (with ProjectName/projectname substitution).
  //
  // THE RUNTIME DIRECTORY HAS TO CARRY THE APP NAME. Copy substitutes file
  // CONTENTS, never path components, so a blanket copy shipped the runtime as
  // lib/projectname/ in every generated SDK. Nothing broke — Elixir resolves
  // modules by their `defmodule`, not by path, and those were substituted
  // correctly — so it compiled, tested green, and published looking wrong.
  //
  // Copy's `to` prop names the destination, so lib/projectname is copied
  // explicitly under the app's own name and excluded from the blanket copy.
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
      // pluginExcludes: the generate-time plugin trim (an INACTIVE plugin
      // group's vendored files, declared per-target in the feature model).
      // Rooted HERE, on lib/projectname, because that is this Copy's root
      // and jostraca matches a candidate against the path relative to it -
      // which is why the model's elixir plugin paths read
      // `feature/secrets/sekreto/plugins/<kind>.ex` and not the full
      // `lib/projectname/...`.
      //
      // AND THE TRIM IS INVISIBLE TO THE COMPILER HERE, unlike everywhere
      // else. mix compiles everything under lib/ and Elixir needs no
      // import, so a plugin file this exclude failed to remove compiles
      // silently and SHIPS - where go fails on an unused import, py on a
      // missing module and ts on an unresolved one. Only the parity and
      // vendored guards can catch a broken trim in this target.
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

    // Operation pipeline (hook markers replaced here — gotcha #1).
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
  })

  // Config module.
  Config({ target })
})


export {
  Main
}
