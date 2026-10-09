import { flowSteps, opReachable, invalidRequest } from '@voxgig/sdkgen'

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
  const allSteps = Object.values(flowSteps(basicflow)) as any[]
  const updateStep = allSteps.find((s: any) => s.o === 'update')
  const updateData = updateStep?.d
    ? Object.entries(updateStep.d).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
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

import ${scalapackage}.core.{Config, Context, Helpers, SdkEntity, SdkError, ${SDK}}
import ${scalapackage}.feature.BaseFeature
import ${scalapackage}.utility.struct.Struct

object ${EntityName}EntityTest {

  import SdkTestSupport.{B, I, jl, om}
${failureTests(SDK, entity, accessor)}
  def run(rep: SdkTestReport): Unit = {
    rep.scope("${ENTLOWER}.instance") {
      val testsdk = ${SDK}.testSDK()
      val ent = testsdk.${accessor}(null)
      rep.check("${ENTLOWER}.instance", ent != null, "expected non-null ${ENTLOWER} entity")
    }
${failureScopes(SDK, entity, accessor)}
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
    const flowHasCreate = allSteps.some((s: any) => s.o === 'create')
    const needsPreambleData = !flowHasCreate &&
      null != entityDataIdField(entity) &&
      allSteps.some((s: any) => ['load', 'update', 'remove'].includes(s.o))
    if (needsPreambleData) {
      const preambleData = scalaVarName(entity.name + '_ref01_data')
      Content(`      val ${preambleData}Raw = Struct.items(Helpers.toMapAny(
          Struct.getpath(entityData, "existing.${ENTLOWER}")))
      val ${preambleData} = Helpers.toMapAny(${preambleData}Raw.get(0).get(1))
`)
    }

    // Model-driven step iteration (sorted-key order for byte-stable output).
    each(flowSteps(basicflow), (step: any, index: any) => {
      const opgen: OpGen = GENERATE_OP[step.o]
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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.i.entvar ?? ref + '_ent')
  const datavar = scalaVarName(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.i.entvar ?? ref + '_ent')
  const matchvar = scalaVarName(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const listvar = scalaVarName(step.i.listvar ?? (ref + '_list' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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

  const hasDataId = null != entityDataIdField(entity)
  const allSteps = Object.values(flowSteps(flow)) as any[]
  const listvarUsed = hasDataId && !!step.v?.some((v: any) => {
    if ('ItemExists' !== v.apply && 'ItemNotExists' !== v.apply) return false
    const validRef = v.def?.ref
    return validRef && allSteps.some((s: any) => 'create' === s.o &&
      ((s.i.ref ?? entity.name + '_ref01') === validRef))
  })

  Content(`      val ${listvar}Result = ${entvar}.list(${matchvar}, null)
      rep.check("${ENTLOWER}.list.islist", ${listvar}Result.isInstanceOf[JList[?]], "expected list result to be an array, got " + ${listvar}Result)
`)
  if (listvarUsed) {
    Content(`      val ${listvar} = ${listvar}Result.asInstanceOf[JList[Object]]
`)
  }

  if (step.v) {
    for (const validator of step.v) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.o &&
        ((s.i.ref ?? entity.name + '_ref01') === validRef))
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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.i.entvar ?? ref + '_ent')
  const datavar = scalaVarName(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))
  const resdatavar = scalaVarName(step.i.resdatavar ?? (ref + '_resdata' + (step.i.suffix ?? '')))
  const markdefvar = scalaVarName(step.i.markdefvar ?? (ref + '_markdef' + (step.i.suffix ?? '')))
  const srcdatavar = scalaVarName(step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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

  if (step.d) {
    const dataEntries = Object.entries(step.d).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`      ${datavar}Up.put("${key}", idmap.get("${key}"))
`)
    }
  }

  let hasMark = false
  if (step.s) {
    for (const spec of step.s) {
      if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
        const fieldname = step.i.textfield
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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.i.entvar ?? ref + '_ent')
  const matchvar = scalaVarName(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const datavar = scalaVarName(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))
  const srcdatavar = scalaVarName(step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  const flowHasCreate = Object.values(flowSteps(flow)).some((s: any) => (s as any).o === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === scalaVarName(preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.o) {
        const priorRef = s.i.ref ?? entity.name + '_ref01'
        const priorDatvar = scalaVarName(s.i.datavar ?? (priorRef + '_data' + (s.i.suffix ?? '')))
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
${parentMatch(step, matchvar)}      val ${datavar}Loaded = ${entvar}.load(${matchvar}, null)
      val ${datavar}LoadResult = Helpers.toMapAny(${datavar}Loaded match { case e: SdkEntity => e.data(); case o => o })
      rep.check("${ENTLOWER}.load.map", ${datavar}LoadResult != null, "expected load result to be a map")
      rep.eq("${ENTLOWER}.load.id", ${srcdatavar}.get("id"), ${datavar}LoadResult.get("id"))
`)
  } else {
    Content(`${parentMatch(step, matchvar)}      val ${datavar}Loaded = ${entvar}.load(${matchvar}, null)
      rep.check("${ENTLOWER}.load.nonnull", ${datavar}Loaded != null, "expected load result to be non-null")
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor, ENTLOWER } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = scalaVarName(step.i.entvar ?? ref + '_ent')
  const matchvar = scalaVarName(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const srcdatavar = scalaVarName(step.i.srcdatavar ?? (ref + '_data'))

  // The remove-by-id match reads ${srcdatavar}.get("id"); skip the whole step
  // when the DATA type has no id field (there is no created id to remove by).
  if (null == entityDataIdField(entity)) {
    return
  }

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  Content(`      // REMOVE
`)
  if (needsEnt) {
    Content(`      val ${entvar} = client.${accessor}(null)
`)
  }
  Content(`      val ${matchvar} = new LinkedHashMap[String, Object]()
      ${matchvar}.put("id", ${srcdatavar}.get("id"))
${parentMatch(step, matchvar)}      ${entvar}.remove(${matchvar}, null)
`)
}


// A child's route names its parents, and an entity no earlier step has
// filled knows none of them, so the call itself gives each parent id.
function parentMatch(step: any, matchvar: string): string {
  return Object.entries(step.m || {})
    .filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    .map(([key, val]: any) => `      ${matchvar}.put("${key}", Option(idmap.get("${key}")).getOrElse(idmap.get("${val}")))
`).join('')
}


const GENERATE_OP: Record<string, OpGen> = {
  create: generateCreate,
  list: generateList,
  update: generateUpdate,
  load: generateLoad,
  remove: generateRemove,
}


// A failed operation throws from a stream as it does from the operation: a
// transport failure, and a hook that rejects the call. A throwing hook fires
// PreUnexpected, under throw false too. The caller's ctrl stays its own. An
// invalid request fails with validate's own error, before it is sent.
function failureTests(SDK: string, entity: ModelEntity, accessor: string): string {
  const hasList = opReachable((entity.op as any)?.list, [])
  if (!hasList && null == invalidRequest(entity)) {
    return ''
  }
  return `
  private def hasFeature(name: String): Boolean = {
    val fm = Helpers.toMapAny(Config.sharedConfig().get("feature"))
    fm != null && fm.get(name) != null
  }
${hasList ? `
  final class FailHook extends BaseFeature("failhook", "0.0.1", true) {
    var unexpected = 0
    override def preSpec(ctx: Context): Unit = throw new RuntimeException("${entity.name} hook failed")
    override def preUnexpected(ctx: Context): Unit = unexpected += 1
  }
` : ''}`
}


function failureScopes(SDK: string, entity: ModelEntity, accessor: string): string {
  const name = entity.name
  let out = ''

  if (opReachable((entity.op as any)?.list, [])) {
    out += `
    rep.scope("${name}.stream.error") {
      val offline = om("net" -> om("offline" -> B(true)))
      val err = try {
        ${SDK}.testSDK(offline, null).${accessor}(null).stream("list", null, null).toList
        null
      } catch { case e: RuntimeException => e }
      rep.check("${name}.stream.error", err != null && String.valueOf(err.getMessage).contains("offline"),
        "expected the transport failure to raise from the stream, got " + err)

      ${SDK}.testSDK(offline, null).${accessor}(null)
        .stream("list", null, om("ctrl" -> om("throw" -> B(false)))).toList

      if (hasFeature("rbac")) {
        val denied = ${SDK}.testSDK(null,
          om("feature" -> om("rbac" -> om("active" -> B(true), "deny" -> B(true)))))
        val denyerr = try {
          denied.${accessor}(null).stream("list", null, null).toList
          null
        } catch { case e: SdkError => e }
        rep.check("${name}.stream.denied", denyerr != null && "rbac_denied" == denyerr.code,
          "expected the rbac denial to raise from the stream, got " + denyerr)
      }
    }

    rep.scope("${name}.stream.ctrl") {
      val explain = new LinkedHashMap[String, Object]()
      val ctrl = om("explain" -> explain)
      ${SDK}.testSDK().${accessor}(null).stream("list", null, om("ctrl" -> ctrl)).toList
      rep.check("${name}.stream.ctrl", 1 == ctrl.size() && (explain eq ctrl.get("explain")),
        "the stream changed the caller's ctrl")
      rep.check("${name}.stream.explain", !explain.isEmpty(), "the caller's explain record was not filled")
    }

    rep.scope("${name}.unexpected") {
      val hook = new FailHook()
      val client = new ${SDK}(om("feature" -> om("test" -> om("active" -> B(true))), "extend" -> jl(hook)))
      val err = try {
        client.${accessor}(null).list(null, null)
        null
      } catch { case e: RuntimeException => e }
      rep.check("${name}.unexpected.raise", err != null && String.valueOf(err.getMessage).contains("hook failed"),
        "expected the hook's failure, got " + err)
      rep.check("${name}.unexpected.fired", hook.unexpected > 0, "PreUnexpected did not fire")

      val fired = hook.unexpected
      client.${accessor}(null).list(null, om("throw" -> B(false)))
      rep.check("${name}.unexpected.nothrow", hook.unexpected > fired,
        "PreUnexpected did not fire under throw false")
    }
`
  }

  const bad = invalidRequest(entity)
  if (null != bad) {
    const args = Object.entries(bad.args)
      .map(([k, v]) => JSON.stringify(k) + ' -> ' +
        ('number' === typeof v ? 'I(' + v + ')' : 'boolean' === typeof v ? 'B(' + v + ')' : JSON.stringify(v)))
      .join(', ')
    out += `
    rep.scope("${name}.validate") {
      if (hasFeature("validate")) {
        val client = ${SDK}.testSDK(null, om("feature" -> om("validate" -> om("active" -> B(true)))))
        val err = try {
          client.${accessor}(null).${bad.op}(om(${args}), null)
          null
        } catch { case e: SdkError => e }
        rep.check("${name}.validate", err != null && "validate_failed" == err.code,
          "expected validate_failed, got " + err)
      }
    }
`
  }

  return out
}


export {
  TestEntity
}
