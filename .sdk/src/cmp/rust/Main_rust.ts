
import * as Path from 'node:path'

import {
  cmp, each,
  File, Content, Copy, Folder, Fragment,
  entityClassName,
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


import { Package } from './Package_rust'
import { Config } from './Config_rust'
import { Schema } from './Schema_rust'
import { PrepareAuth } from './PrepareAuth_rust'
import { Gitignore } from './Gitignore_rust'
import { MainEntity } from './MainEntity_rust'
import { EntityBase } from './EntityBase_rust'
import { EntityTypes } from './EntityTypes_rust'
import { SdkError } from './SdkError_rust'
import { crateIdent } from './utility_rust'


const Main = cmp(async function Main(props: any) {

  const { target } = props
  const { model } = props.ctx$

  const entity: ModelEntity = getModelPath(model, `main.${KIT}.entity`)
  // Gated by the applicability tags, so this target never imports or
  // registers a feature it has no source for. One rule, one place:
  // helpers/applicability.
  const feature = targetFeatures(model, target)

  const rustcrate = crateIdent(model)

  Package({ target })

  Gitignore({})

  // Copy tm/rust files with replacements. The tm src/ subtree only stages
  // the per-feature custom-source dirs (target add), so it is excluded
  // here exactly like the go target.
  Copy({
    from: 'tm/' + target.name,
    // pluginExcludes: the generate-time plugin trim (an INACTIVE plugin
    // group's declared files stay out of the tree - the model's `path`
    // entries are target-root-relative, which is this Copy's root). The
    // FEATURE-level trim for rust stays an add-time concern, as go's does.
    exclude: [/src\//, TEST_CONTROL_EXCLUDE, ...pluginExcludes(model)],
    replace: {
      ...props.ctx$.stdrep,
      RUSTCRATE: rustcrate,
    }
  })

  PrepareAuth({ target })

  Folder({ name: 'core' }, () => {

    File({ name: 'sdk.' + target.ext }, () => {

      Fragment(
        {
          from: Path.normalize(__dirname + '/../../../src/cmp/rust/fragment/Main.fragment.rs'),
          replace: {
            ...props.ctx$.stdrep,
          }
        },

        () => {
          each(entity, (entity: ModelEntity) => {
            const entitySDK = getModelPath(model, `main.${KIT}.entity.${entity.name}`)
            const entprops = { target, entity, entitySDK }
            MainEntity(entprops)
          })
        })
    })

    Config({ target })

    Schema({ target })

    SdkError({ target })
  })

  Folder({ name: 'feature' }, () => {
    File({ name: 'mod.' + target.ext }, () => {
      Content(`// ${model.const.Name} SDK feature modules (mirrors tm/go/feature).
// Each feature is a Feature trait object registered on the client;
// \`support\` carries the shared option readers (go feature_options.go).

pub mod support;

pub mod base;
`)
      each(feature, (feat: any) => Content(`pub mod ${feat.name};\n`))
    })

    each(feature, (feat: any) => {
      const declared = getModelPath(model,
        `main.${KIT}.feature.${feat.name}.plugin`,
        { required: false, only_active: false }) || {}

      if (0 === Object.keys(declared).length) {
        return
      }

      const mods = new Set<string>()
      const syms = new Set<string>()

      each(declared, (plugin: any) => {
        // Filter on `active` HERE (Config_go's note): getting this wrong
        // declares a module for a file the trim just removed, which is a
        // compile error rather than a silent one.
        if (true !== plugin.active) return

        for (const [sym, one] of Object.entries(plugin.def?.rust || {})) {
          mods.add(String(one).replace(/^.*\//, '').replace(/\.rs$/, ''))
          syms.add(sym)
        }
      })

      const NOHTTP = ['secretspec']
      const http = Array.from(mods).some((m: string) => !NOHTTP.includes(m))

      Folder({ name: feat.name }, () => {
        File({ name: 'plugins.' + target.ext }, () => {
          Content(`// The plugin definitions the model selected for the \`${feat.name}\`
// feature, and the modules they live in (generated - see Main_rust).
//
// Upstream sekreto's contract since its registry was retired: a provider
// kind not handed to the constructor is unknown to that Sekreto. So this
// list IS the SDK's provider vocabulary, and a kind nobody selected is
// neither declared nor compiled.

use crate::feature::${feat.name}::plugin::catalog::Definition;

`)
          if (http) {
            Content(`pub mod httpjson;
`)
          }
          for (const m of Array.from(mods).sort()) {
            Content(`pub mod ${m};
`)
          }

          Content(`
pub fn definitions() -> Vec<Definition> {
    vec![
`)
          for (const sym of Array.from(syms).sort()) {
            Content(`        ${sym}(),
`)
          }
          Content(`    ]
}
`)
        })
      })
    })
  })

  EntityBase({ target })

  EntityTypes({ target })

  File({ name: 'lib.' + target.ext }, () => {
    Content(`// ${model.const.Name} SDK for Rust (generated by @voxgig/sdkgen).
//
// The crate mirrors the go SDK layout: core/ (pipeline types), feature/
// (pipeline features), utility/ (pipeline utilities + the vendored voxgig
// struct port), entity/ (per-entity clients). The crate root is this file
// (see Cargo.toml [lib] path).

pub mod core;
pub mod entity;
pub mod feature;
pub mod utility;

// Public API re-exports.
pub use crate::core::config::{make_config, make_feature};
pub use crate::core::context::{Context, CtxSpec, OpMap};
pub use crate::core::control::Control;
pub use crate::core::error::${model.const.Name}Error;
pub use crate::core::helpers::{
    call_json, call_vfn, ja, jo, json_thunk, unsupported_op, vfn,
};
pub use crate::core::operation::Operation;
pub use crate::core::point::Point;
pub use crate::core::response::Response;
pub use crate::core::result::{SdkResult, StreamFn};
pub use crate::core::sdk::{test_sdk, ${model.const.Name}SDK};
pub use crate::core::spec::Spec;
pub use crate::core::types::{
    Entity, Feature, FeatureRef, FetcherFn, OutVal, ${model.const.Name}Entity,
};
pub use crate::core::utility_type::Utility;
pub use crate::feature::base::BaseFeature;
pub use crate::utility::jsonparse::json_parse;
pub use crate::utility::voxgigstruct::Value;

// No-argument convenience constructors: \`${rustcrate}::new()\` /
// \`${rustcrate}::test()\` for the common no-options case.
use std::rc::Rc;

pub fn new() -> Rc<${model.const.Name}SDK> {
    ${model.const.Name}SDK::new(Value::Noval)
}

pub fn test() -> Rc<${model.const.Name}SDK> {
    test_sdk(Value::Noval, Value::Noval)
}
`)
  })

})


export {
  Main
}
