
import {
  KIT,
  Model,
  ModelEntity,
  ModelEntityFlow,
  ModelEntityFlowStep,
  getModelPath,
  nom,
} from '@voxgig/apidef'


import {
  Content,
  File,
  cmp,
  each,
  buildIdNames,
  getMatchEntries,
  entityDataIdField,
} from '@voxgig/sdkgen'


import { scalaVarName } from './utility_scala'


// Scala GenCtx mirrors the java donor's shape (see TestEntity_java.ts). The
// scala per-entity test is a dependency-free scala-cli object (default
// package) exposing run(rep) — driven by the generated SdkEntityTestMain
// aggregator. Only the offline unit path is emitted: the in-memory test
// transport serves the fixtures, so there is no live/env/synthetic machinery.
type GenCtx = {
  model: Model
  entity: ModelEntity
  flow: ModelEntityFlow
  accessor: string
  ENTLOWER: string
}

type OpGen = (ctx: GenCtx, step: ModelEntityFlowStep, index: number) => void


const TestEntity = cmp(function TestEntity(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity
  const scalapackage: string = props.scalapackage

  const EntityName = nom(entity, 'Name')

  const basicflow: ModelEntityFlow | undefined =
    getModelPath(model, `main.${KIT}.flow.Basic${EntityName}Flow`)
  if (null == basicflow || true !== basicflow.active) {
    return
  }

  const SDK = model.const.Name + 'SDK'
  const accessor = scalaVarName(entity.name)
  const ENTLOWER = entity.name

  // Build the placeholder idmap (name -> UPPER(name)), matching the java
  // setup's Struct.transform(idnames, {upper}). Aliases from the update
  // step's data are pre-resolved so update ops fetch ancestor ids by name.
  const idnames = buildIdNames(entity, basicflow)
  const idmapObj: Record<string, string> = {}
  for (const n of idnames) {
    idmapObj[n] = String(n).toUpperCase()
  }
  const allSteps = Object.values(basicflow.step) as any[]
  const updateStep = allSteps.find((s: any) => s.op === 'update')
  const updateData = updateStep?.data
    ? Object.entries(updateStep.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  for (const [k, v] of updateData as any[]) {
    if (null == idmapObj[k] && null != idmapObj[v as string]) {
      idmapObj[k] = idmapObj[v as string]
    }
  }

  const genCtx: GenCtx = { model, entity, flow: basicflow, accessor, ENTLOWER }

  File({ name: EntityName + 'EntityTest.' + target.ext }, () => {

    Content(`// Generated basic-flow test for the ${ENTLOWER} entity (model-driven;
// mirrors the java TestEntity generator). A dependency-free scala-cli test
// object driven by SdkEntityTestMain. Runs against the in-memory test
// transport seeded with the shipped ${EntityName}TestData.json fixtures.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}

import ${scalapackage}.core.{Helpers, SdkEntity, ${SDK}}
import ${scalapackage}.utility.struct.Struct

object ${EntityName}EntityTest {

  def run(rep: SdkTestReport): Unit = {
    rep.scope("${ENTLOWER}.instance") {
      val testsdk = ${SDK}.testSDK()
      val ent = testsdk.${accessor}(null)
      rep.check("${ENTLOWER}.instance", ent != null, "expected non-null ${ENTLOWER} entity")
    }

    rep.scope("${ENTLOWER}.basic") {
      val entityData = Helpers.toMapAny(SdkTestSupport.readJson(
          "../.sdk/test/entity/${ENTLOWER}/${EntityName}TestData.json"))
      val options = new LinkedHashMap[String, Object]()
      options.put("entity", entityData.get("existing"))
      val client = ${SDK}.testSDK(options, null)

      val idmap = new LinkedHashMap[String, Object]()
`)

    for (const key of Object.keys(idmapObj)) {
      Content(`      idmap.put("${key}", "${idmapObj[key]}")
`)
    }

    Content(`      val now = System.currentTimeMillis()
`)

    // Preamble bootstrap: a flow with no `create` step (e.g. a read-only
    // load/list entity) has nothing to declare the standard `<ref>_data` var
    // that a later load/update/remove reads its id from. Seed it from the
    // shipped "existing" fixtures here, mirroring the ts generator. Guarded on a
    // DATA id field — an entity that carries no id has no `.get("id")` to read.
    const flowHasCreate = allSteps.some((s: any) => s.op === 'create')
    const needsPreambleData = !flowHasCreate &&
      null != entityDataIdField(entity) &&
      allSteps.some((s: any) => ['load', 'update', 'remove'].includes(s.op))
    if (needsPreambleData) {
      const preambleData = scalaVarName(entity.name + '_ref01_data')
      Content(`      val ${preambleData}Raw = Struct.items(Helpers.toMapAny(
          Struct.getpath(entityData, "existing.${ENTLOWER}")))
      val ${preambleData} = Helpers.toMapAny(${preambleData}Raw.get(0).get(1))
`)
    }

    // Model-driven step iteration (sorted-key order for byte-stable output).
    each(basicflow.step, (step: any, index: any) => {
      const opgen: OpGen = GENERATE_OP[step.op]
      if (opgen) {
        Content('\n')
        opgen(genCtx, step, index)
      }
    })

    Content(`    }
  }
}
`)
  })
})


const generateCreate: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor, ENTLOWER } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.input.entvar ?? ref + '_ent')
  const datavar = scalaVarName(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`      // CREATE
`)
  if (needsEnt) {
    Content(`      val ${entvar} = client.${accessor}(null)
`)
  }
  Content(`      var ${datavar} = Helpers.toMapAny(Struct.getprop(
          Struct.getpath(entityData, "new.${ENTLOWER}"), "${ref}"))
`)

  const matchEntries = getMatchEntries(step)
  for (const [key, val] of matchEntries) {
    Content(`      ${datavar}.put("${key}", idmap.get("${val}"))
`)
  }

  Content(`      val ${datavar}Result = ${entvar}.create(${datavar}, null)
      ${datavar} = Helpers.toMapAny(${datavar}Result match { case e: SdkEntity => e.data(); case o => o })
      rep.check("${ENTLOWER}.create.map", ${datavar} != null, "expected create result to be a map")
`)
  if (null != entityDataIdField(entity)) {
    Content(`      rep.check("${ENTLOWER}.create.id", ${datavar} != null && ${datavar}.get("id") != null, "expected created entity to have an id")
`)
  }
}


const generateList: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor, ENTLOWER } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.input.entvar ?? ref + '_ent')
  const matchvar = scalaVarName(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const listvar = scalaVarName(step.input.listvar ?? (ref + '_list' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`      // LIST
`)
  if (needsEnt) {
    Content(`      val ${entvar} = client.${accessor}(null)
`)
  }

  const matchEntries = getMatchEntries(step)
  Content(`      val ${matchvar} = new LinkedHashMap[String, Object]()
`)
  for (const [key, val] of matchEntries) {
    Content(`      ${matchvar}.put("${key}", idmap.get("${val}"))
`)
  }

  // Select-by-id assertions require the DATA type to carry an id field
  // (entityDataIdField); an entity keyed only on a load-MATCH id it does not
  // return as data has no `.get("id")` to compare, so skip them.
  const hasDataId = null != entityDataIdField(entity)
  const allSteps = Object.values(flow.step) as any[]
  const listvarUsed = hasDataId && !!step.valid?.some((v: any) => {
    if ('ItemExists' !== v.apply && 'ItemNotExists' !== v.apply) return false
    const validRef = v.def?.ref
    return validRef && allSteps.some((s: any) => 'create' === s.op &&
      ((s.input.ref ?? entity.name + '_ref01') === validRef))
  })

  Content(`      val ${listvar}Result = ${entvar}.list(${matchvar}, null)
      rep.check("${ENTLOWER}.list.islist", ${listvar}Result.isInstanceOf[JList[?]], "expected list result to be an array, got " + ${listvar}Result)
`)
  if (listvarUsed) {
    Content(`      val ${listvar} = ${listvar}Result.asInstanceOf[JList[Object]]
`)
  }

  if (step.valid) {
    for (const validator of step.valid) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.op &&
        ((s.input.ref ?? entity.name + '_ref01') === validRef))
      const refDataVar = scalaVarName(validRef + '_data')

      if ('ItemExists' === validator.apply && hasRefData && hasDataId) {
        Content(`      val ${listvar}Found = Struct.select(
          SdkTestSupport.entityListToData(${listvar}), SdkTestSupport.om("id" -> ${refDataVar}.get("id")))
      rep.check("${ENTLOWER}.list.exists", !Struct.isempty(${listvar}Found), "expected to find created entity in list")
`)
      } else if ('ItemNotExists' === validator.apply && hasRefData && hasDataId) {
        Content(`      val ${listvar}NotFound = Struct.select(
          SdkTestSupport.entityListToData(${listvar}), SdkTestSupport.om("id" -> ${refDataVar}.get("id")))
      rep.check("${ENTLOWER}.list.notexists", Struct.isempty(${listvar}NotFound), "expected removed entity to not be in list")
`)
      }
    }
  }
}


const generateUpdate: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor, ENTLOWER } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.input.entvar ?? ref + '_ent')
  const datavar = scalaVarName(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))
  const resdatavar = scalaVarName(step.input.resdatavar ?? (ref + '_resdata' + (step.input.suffix ?? '')))
  const markdefvar = scalaVarName(step.input.markdefvar ?? (ref + '_markdef' + (step.input.suffix ?? '')))
  const srcdatavar = scalaVarName(step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const hasDataId = null != entityDataIdField(entity)

  Content(`      // UPDATE
`)
  if (needsEnt) {
    Content(`      val ${entvar} = client.${accessor}(null)
`)
  }
  Content(`      val ${datavar}Up = new LinkedHashMap[String, Object]()
`)
  if (hasDataId) {
    Content(`      ${datavar}Up.put("id", ${srcdatavar}.get("id"))
`)
  }

  if (step.data) {
    const dataEntries = Object.entries(step.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`      ${datavar}Up.put("${key}", idmap.get("${key}"))
`)
    }
  }

  let hasMark = false
  if (step.spec) {
    for (const spec of step.spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        const fieldname = step.input.textfield
        const fieldvalue = spec.def?.mark ?? `Mark01-${ref}`
        hasMark = true
        Content(`      val ${markdefvar}Name = "${fieldname}"
      val ${markdefvar}Value = "${fieldvalue}_" + now
      ${datavar}Up.put(${markdefvar}Name, ${markdefvar}Value)
`)
      }
    }
  }

  Content(`      val ${resdatavar}Result = ${entvar}.update(${datavar}Up, null)
      val ${resdatavar} = Helpers.toMapAny(${resdatavar}Result match { case e: SdkEntity => e.data(); case o => o })
      rep.check("${ENTLOWER}.update.map", ${resdatavar} != null, "expected update result to be a map")
`)
  if (hasDataId) {
    Content(`      rep.eq("${ENTLOWER}.update.id", ${datavar}Up.get("id"), ${resdatavar}.get("id"))
`)
  }
  if (hasMark) {
    Content(`      rep.eq("${ENTLOWER}.update.mark", ${markdefvar}Value, ${resdatavar}.get(${markdefvar}Name))
`)
  }
}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor, ENTLOWER } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.input.entvar ?? ref + '_ent')
  const matchvar = scalaVarName(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const datavar = scalaVarName(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))
  const srcdatavar = scalaVarName(step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const flowHasCreate = Object.values(flow.step).some((s: any) => (s as any).op === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === scalaVarName(preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.op) {
        const priorRef = s.input.ref ?? entity.name + '_ref01'
        const priorDatvar = scalaVarName(s.input.datavar ?? (priorRef + '_data' + (s.input.suffix ?? '')))
        return priorDatvar === srcdatavar
      }
      return false
    })

  const hasDataId = null != entityDataIdField(entity)

  Content(`      // LOAD
`)
  if (!hasEntVar) {
    Content(`      val ${entvar} = client.${accessor}(null)
`)
  }
  if (!hasSrcData && hasDataId) {
    Content(`      val ${srcdatavar}Raw = Struct.items(Helpers.toMapAny(
          Struct.getpath(entityData, "existing.${ENTLOWER}")))
      val ${srcdatavar} = Helpers.toMapAny(${srcdatavar}Raw.get(0).get(1))
`)
  }
  Content(`      val ${matchvar} = new LinkedHashMap[String, Object]()
`)
  if (hasDataId) {
    Content(`      ${matchvar}.put("id", ${srcdatavar}.get("id"))
      val ${datavar}Loaded = ${entvar}.load(${matchvar}, null)
      val ${datavar}LoadResult = Helpers.toMapAny(${datavar}Loaded match { case e: SdkEntity => e.data(); case o => o })
      rep.check("${ENTLOWER}.load.map", ${datavar}LoadResult != null, "expected load result to be a map")
      rep.eq("${ENTLOWER}.load.id", ${srcdatavar}.get("id"), ${datavar}LoadResult.get("id"))
`)
  } else {
    Content(`      val ${datavar}Loaded = ${entvar}.load(${matchvar}, null)
      rep.check("${ENTLOWER}.load.nonnull", ${datavar}Loaded != null, "expected load result to be non-null")
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor, ENTLOWER } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.input.entvar ?? ref + '_ent')
  const matchvar = scalaVarName(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const srcdatavar = scalaVarName(step.input.srcdatavar ?? (ref + '_data'))

  // The remove-by-id match reads ${srcdatavar}.get("id"); skip the whole step
  // when the DATA type has no id field (there is no created id to remove by).
  if (null == entityDataIdField(entity)) {
    return
  }

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`      // REMOVE
`)
  if (needsEnt) {
    Content(`      val ${entvar} = client.${accessor}(null)
`)
  }
  Content(`      val ${matchvar} = new LinkedHashMap[String, Object]()
      ${matchvar}.put("id", ${srcdatavar}.get("id"))
      ${entvar}.remove(${matchvar}, null)
`)
}


const GENERATE_OP: Record<string, OpGen> = {
  create: generateCreate,
  list: generateList,
  update: generateUpdate,
  load: generateLoad,
  remove: generateRemove,
}


export {
  TestEntity
}
