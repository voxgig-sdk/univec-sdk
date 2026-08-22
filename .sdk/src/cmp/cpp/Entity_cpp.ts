
import * as Path from 'node:path'

import {
  cmp, camelify,
  File, Content, Folder, Fragment,
  entityClassName, entityCollection,
} from '@voxgig/sdkgen'

import {
  KIT,
  getModelPath
} from '@voxgig/apidef'

import { EntityOperation } from './EntityOperation_cpp'
import { cppVarName } from './utility_cpp'


const Entity = cmp(function Entity(props: any) {
  const { model, stdrep } = props.ctx$
  const { target, entity } = props

  const entityColl = entityCollection(model)
  const cls = entityClassName(entity, entityColl)

  const entrep = {
    ...stdrep,
  }

  const ff = Path.normalize(__dirname + '/../../../src/cmp/cpp/fragment/')

  Folder({ name: 'entity' }, () => {

    File({ name: cppVarName(entity.name) + '.' + target.ext }, () => {

      const opnames = Object.keys(entity.op || {})

      // For each CRUD op: splice the real method if the spec defines it, else
      // a stub that satisfies the SdkEntity interface but throws at runtime.
      const opfrags =
        (['load', 'list', 'create', 'update', 'remove']
          .reduce((a: any, opname: string) =>
          (a['#' + camelify(opname) + 'Op'] =
            !opnames.includes(opname) ?
              ({ indent }: any) => {
                const arg = ('create' === opname || 'update' === opname) ?
                  'reqdata' : 'reqmatch'
                // The stub mirrors the real signature: ops resolve to the
                // ENTITY (`list` to a vector of them), so an unsupported op
                // has to declare the same return type to satisfy SdkEntity.
                const ret = 'list' === opname ? 'std::vector<SdkEntityPtr>' : 'SdkEntityPtr'
                Content({ indent }, `${ret} ${opname}(const Value& ${arg}, const Value& ctrl) override {
    (void)${arg}; (void)ctrl;
    throw Helpers::unsupportedOp("${opname}", this->name_);
  }
`)
              } :
              ({ indent }: any) => {
                EntityOperation({ ff, opname, indent, entity, entrep, cls })
              }, a), {}))

      Fragment({
        from: ff + 'Entity.fragment.cpp',
        replace: {
          ...entrep,
          ProjectName: model.const.Name,
          EntityName: entity.Name,
          entityname: entity.name,
          EntyClass: cls,

          ...opfrags,
        }
      })

    })
  })
})


export {
  Entity
}
