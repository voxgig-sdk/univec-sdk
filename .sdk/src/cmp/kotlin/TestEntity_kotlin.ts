import { flowSteps } from '@voxgig/sdkgen'

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
  isAuthActive, envName, envToken
} from '@voxgig/sdkgen'


import { kotlinVarName } from './utility_kotlin'


// Convert snake_case to camelCase for Kotlin variable names.
function kvar(name: string): string {
  return name.replace(/_([a-z0-9])/g, (_: any, c: string) => c.toUpperCase())
}


type GenCtx = {
  model: Model
  entity: ModelEntity
  kotlinpackage: string
  flow: ModelEntityFlow
  PROJUPPER: string
  accessor: string
}

type OpGen = (ctx: GenCtx, step: ModelEntityFlowStep, index: number) => void


const TestEntity = cmp(function TestEntity(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity
  const kotlinpackage: string = props.kotlinpackage

  const basicflow: ModelEntityFlow | undefined =
    getModelPath(model, `main.${KIT}.flow.Basic${nom(entity, 'Name')}Flow`)
  if (null == basicflow || true !== basicflow.active) {
    return
  }

  const PROJUPPER = envName(model)
  const ENTUPPER = envToken(entity.name)
  const entidEnvVar = `${PROJUPPER}_TEST_${ENTUPPER}_ENTID`

  const SDK = model.const.Name + 'SDK'
  const accessor = kotlinVarName(entity.name)

  const authActive = isAuthActive(model)

  const idnames = buildIdNames(entity, basicflow)

  const allSteps = Object.values(flowSteps(basicflow)) as any[]
  const updateStep = allSteps.find((s: any) => s.o === 'update')
  const updateData = updateStep?.d
    ? Object.entries(updateStep.d).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  const aliases = updateData.map(([k, v]: any) => [k, v])

  const genCtx: GenCtx = { model, entity, kotlinpackage, flow: basicflow, PROJUPPER, accessor }

  const stepOps = Array.from(new Set(
    (allSteps as any[]).map((s: any) => s.o).filter(Boolean)))

  File({ name: entity.Name + 'EntityTest.' + target.ext }, () => {

    Content(`package ${kotlinpackage}.sdktest

import java.nio.file.Files
import java.nio.file.Paths

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.Test

import ${kotlinpackage}.core.Helpers
import ${kotlinpackage}.core.SdkEntity
import ${kotlinpackage}.core.${SDK}
import ${kotlinpackage}.utility.Json
import ${kotlinpackage}.utility.struct.Struct

@Suppress("UNCHECKED_CAST", "UNUSED_VARIABLE", "UNUSED_VALUE")
class ${entity.Name}EntityTest {

  @Test
  fun instance() {
    val testsdk = ${SDK}.testSDK()
    val ent = testsdk.${accessor}(null)
    assertNotNull(ent, "expected non-null ${entity.name} entity")
  }

  @Test
  fun basic() {
    val setup = ${accessor}BasicSetup(null)
    // Per-op sdk-test-control.json skip.
    val mode = if (setup.live) "live" else "unit"
    for (op in arrayOf<String>(${stepOps.map(o => `"${o}"`).join(', ')})) {
      val reason = RunnerSupport.skipReason("entityOp", "${entity.name}.\$op", mode)
      Assumptions.assumeTrue(
        reason == null,
        if (reason == null || "" == reason) "skipped via sdk-test-control.json" else reason,
      )
    }
    Assumptions.assumeFalse(
      setup.syntheticOnly,
      "live entity test uses synthetic IDs from fixture — set ${entidEnvVar} JSON to run live",
    )
${allSteps.length > 0 ? `    val client = setup.client\n\n` : ''}`)

    const flowHasCreate = allSteps.some((s: any) => s.o === 'create')
    if (!flowHasCreate) {
      const preambleRef = entity.name + '_ref01'
      const preambleVar = kvar(preambleRef)
      Content(`    // Bootstrap entity data from existing test data (no create step in flow).
    val ${preambleVar}DataRaw = Struct.items(Helpers.toMapAny(
        Struct.getpath(setup.data, "existing.${entity.name}")))
    val ${preambleVar}Data: MutableMap<String, Any?> = if (${preambleVar}DataRaw.isEmpty())
        linkedMapOf() else (Helpers.toMapAny(${preambleVar}DataRaw[0][1]) ?: linkedMapOf())

`)
    }

    each(flowSteps(basicflow), (step: any, index: any) => {
      const opgen: OpGen = GENERATE_OP[step.o]
      if (opgen) {
        opgen(genCtx, step, index)
        Content('\n')
      }
    })

    Content(`  }

`)

    const flowHasList = allSteps.some((s: any) => s.o === 'list')
    if (flowHasList) {
      Content(`  @Test
  fun stream() {
    val streamingActive = linkedMapOf<String, Any?>(
      "feature" to linkedMapOf<String, Any?>(
        "streaming" to linkedMapOf<String, Any?>("active" to true),
      ),
    )
    val setup = ${accessor}BasicSetup(streamingActive)
    Assumptions.assumeFalse(
      setup.live,
      "stream test streams the seeded fixture data (unit mode only)",
    )

    val ent = setup.client.${accessor}(null)
    val match = linkedMapOf<String, Any?>()

    // Materialised list result for the same op.
    val listedResult = ent.list(match, null)
    val listed = (listedResult as? List<Any?>) ?: emptyList<Any?>()

    // stream("list") yields items via the streaming feature's iterator.
    val streamed = ent.stream("list", match, null).toList()
    assertTrue(streamed.size > 0, "expected stream to yield items")
    assertEquals(listed.size, streamed.size, "expected stream to match list count")

    // Fallback: with streaming inactive, stream still yields the materialised
    // items.
    val setup2 = ${accessor}BasicSetup(null)
    val ent2 = setup2.client.${accessor}(null)
    val streamed2 = ent2.stream("list", match, null).toList()
    assertEquals(listed.size, streamed2.size, "expected fallback stream to match list")
  }

`)
    }

    // Setup function (companion object).
    Content(`  companion object {
    fun ${accessor}BasicSetup(extra: MutableMap<String, Any?>?): RunnerSupport.EntityTestSetup {
      RunnerSupport.loadEnvLocal()

      val entityData: MutableMap<String, Any?>
      try {
        val entityDataSource = Files.readString(Paths.get(
            "..", ".sdk", "test", "entity", "${entity.name}", "${entity.Name}TestData.json"))
        entityData = Helpers.toMapAny(Json.parse(entityDataSource)) ?: linkedMapOf()
      } catch (e: Exception) {
        throw AssertionError("failed to read ${entity.name} test data: " + e.message, e)
      }

      val options = linkedMapOf<String, Any?>()
      options["entity"] = entityData["existing"]

      var client = ${SDK}.testSDK(options, extra)

      // Generate idmap via transform, matching TS pattern.
      val idnames = mutableListOf<Any?>()
`)

    for (const n of idnames) {
      Content(`      idnames.add("${n}")
`)
    }

    Content(`      val idmap = Struct.transform(idnames, Json.parse(
          "{\\"\`\\$PACK\`\\": [\\"\\", {" +
          "\\"\`\\$KEY\`\\": \\"\`\\$COPY\`\\"," +
          "\\"\`\\$VAL\`\\": [\\"\`\\$FORMAT\`\\", \\"upper\\", \\"\`\\$COPY\`\\"]" +
          "}]}"))

      // Detect ENTID env override before envOverride consumes it.
      val entidEnvRaw = RunnerSupport.getenv("${entidEnvVar}")
      val idmapOverridden = entidEnvRaw != null && entidEnvRaw.trim().startsWith("{")

      val envm = linkedMapOf<String, Any?>()
      envm["${entidEnvVar}"] = idmap
      envm["${PROJUPPER}_TEST_LIVE"] = "FALSE"
      envm["${PROJUPPER}_TEST_EXPLAIN"] = "FALSE"
${authActive ? `      envm["${PROJUPPER}_APIKEY"] = "NONE"\n` : ''}      val env = RunnerSupport.envOverride(envm)

      var idmapResolved = Helpers.toMapAny(env["${entidEnvVar}"])
      if (idmapResolved == null) {
        idmapResolved = Helpers.toMapAny(idmap) ?: linkedMapOf()
      }
`)

    for (const [key, val] of aliases) {
      Content(`      // Add ${key} alias for update test.
      if (idmapResolved["${key}"] == null) {
        idmapResolved["${key}"] = idmapResolved["${val}"]
      }
`)
    }

    Content(`
      val live = "TRUE" == env["${PROJUPPER}_TEST_LIVE"]
      if (live) {
        val liveOpts = linkedMapOf<String, Any?>()
${authActive ? `        liveOpts["apikey"] = env["${PROJUPPER}_APIKEY"]\n` : ''}        val mergedOpts = Struct.merge(Struct.jt(liveOpts, extra))
        client = ${SDK}(Helpers.toMapAny(mergedOpts))
      }

      val setup = RunnerSupport.EntityTestSetup()
      setup.client = client
      setup.data = entityData
      setup.idmap = idmapResolved
      setup.env = env
      setup.explain = "TRUE" == env["${PROJUPPER}_TEST_EXPLAIN"]
      setup.live = live
      setup.syntheticOnly = live && !idmapOverridden
      setup.now = System.currentTimeMillis()
      return setup
    }
  }
}
`)
  })
})


const generateCreate: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = kvar(step.i.entvar ?? ref + '_ent')
  const datavar = kvar(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  const hasDatvar = priorSteps.some((s: any) => {
    if ('create' === s.o) {
      const priorRef = s.i.ref ?? entity.name + '_ref01'
      const priorDatvar = kvar(s.i.datavar ?? (priorRef + '_data' + (s.i.suffix ?? '')))
      return priorDatvar === datavar
    }
    return false
  })

  Content(`    // CREATE
`)
  if (needsEnt) {
    Content(`    val ${entvar} = client.${accessor}(null)
`)
  }

  const decl = hasDatvar ? '' : 'var '
  Content(`    ${decl}${datavar}: MutableMap<String, Any?> = (Helpers.toMapAny(Struct.getprop(
        Struct.getpath(setup.data, "new.${entity.name}"), "${ref}")) ?: linkedMapOf())
`)

  const matchEntries = getMatchEntries(step)
  for (const [key, val] of matchEntries) {
    Content(`    ${datavar}["${key}"] = setup.idmap!!["${val}"]
`)
  }

  Content(`
    val ${datavar}Result = ${entvar}.create(${datavar}, null)
    ${datavar} = Helpers.toMapAny(if (${datavar}Result is SdkEntity) ${datavar}Result.data() else ${datavar}Result) ?: linkedMapOf()
    assertNotNull(${datavar}, "expected create result to be a map")
`)
  if (null != ctx.entity.id) {
    Content(`    assertNotNull(${datavar}["id"], "expected created entity to have an id")
`)
  }
}


const generateList: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = kvar(step.i.entvar ?? ref + '_ent')
  const matchvar = kvar(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const listvar = kvar(step.i.listvar ?? (ref + '_list' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  Content(`    // LIST
`)
  if (needsEnt) {
    Content(`    val ${entvar} = client.${accessor}(null)
`)
  }

  const matchEntries = getMatchEntries(step)
  Content(`    val ${matchvar} = linkedMapOf<String, Any?>()
`)
  for (const [key, val] of matchEntries) {
    Content(`    ${matchvar}["${key}"] = setup.idmap!!["${val}"]
`)
  }

  const allSteps = Object.values(flowSteps(flow)) as any[]
  const listvarUsed = !!step.v?.some((v: any) => {
    if ('ItemExists' !== v.apply && 'ItemNotExists' !== v.apply) return false
    const validRef = v.def?.ref
    return validRef && allSteps.some((s: any) => 'create' === s.o &&
      ((s.i.ref ?? entity.name + '_ref01') === validRef))
  })

  Content(`
    val ${listvar}Result = ${entvar}.list(${matchvar}, null)
    assertTrue(${listvar}Result is List<*>,
        "expected list result to be an array, got " + ${listvar}Result)
`)
  if (listvarUsed) {
    Content(`    val ${listvar} = ${listvar}Result as List<Any?>
`)
  }

  if (step.v) {
    for (const validator of step.v) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.o &&
        ((s.i.ref ?? entity.name + '_ref01') === validRef))

      if ('ItemExists' === validator.apply && hasRefData) {
        const refDataVar = kvar(validRef + '_data')
        Content(`
    val foundItem = Struct.select(
        RunnerSupport.entityListToData(${listvar}),
        Struct.jm("id", ${refDataVar}["id"]))
    assertFalse(Struct.isempty(foundItem), "expected to find created entity in list")
`)
      } else if ('ItemNotExists' === validator.apply && hasRefData) {
        const refDataVar = kvar(validRef + '_data')
        Content(`
    val notFoundItem = Struct.select(
        RunnerSupport.entityListToData(${listvar}),
        Struct.jm("id", ${refDataVar}["id"]))
    assertTrue(Struct.isempty(notFoundItem), "expected removed entity to not be in list")
`)
      }
    }
  }
}


const generateUpdate: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = kvar(step.i.entvar ?? ref + '_ent')
  const datavar = kvar(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))
  const resdatavar = kvar(step.i.resdatavar ?? (ref + '_resdata' + (step.i.suffix ?? '')))
  const markdefvar = kvar(step.i.markdefvar ?? (ref + '_markdef' + (step.i.suffix ?? '')))
  const srcdatavar = kvar(step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  const hasEntIdU = null != entity.id

  Content(`    // UPDATE
`)
  if (needsEnt) {
    Content(`    val ${entvar} = client.${accessor}(null)
`)
  }
  Content(`    val ${datavar}Up = linkedMapOf<String, Any?>()
`)
  if (hasEntIdU) {
    Content(`    ${datavar}Up["id"] = ${srcdatavar}["id"]
`)
  }

  if (step.d) {
    const dataEntries = Object.entries(step.d).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`    ${datavar}Up["${key}"] = setup.idmap!!["${key}"]
`)
    }
  }

  if (step.s) {
    for (const spec of step.s) {
      if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
        const fieldname = step.i.textfield
        const fieldvalue = spec.def?.mark ?? `Mark01-${ref}`
        Content(`
    val ${markdefvar}Name = "${fieldname}"
    val ${markdefvar}Value = "${fieldvalue}_" + setup.now
    ${datavar}Up[${markdefvar}Name] = ${markdefvar}Value
`)
      }
    }
  }

  Content(`
    val ${resdatavar}Result = ${entvar}.update(${datavar}Up, null)
    val ${resdatavar} = Helpers.toMapAny(if (${resdatavar}Result is SdkEntity) ${resdatavar}Result.data() else ${resdatavar}Result) ?: linkedMapOf()
    assertNotNull(${resdatavar}, "expected update result to be a map")
`)
  if (hasEntIdU) {
    Content(`    assertEquals(${datavar}Up["id"], ${resdatavar}["id"],
        "expected update result id to match")
`)
  }

  if (step.s) {
    for (const spec of step.s) {
      if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
        Content(`    assertEquals(${markdefvar}Value, ${resdatavar}[${markdefvar}Name],
        "expected " + ${markdefvar}Name + " to be updated")
`)
      }
    }
  }
}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = kvar(step.i.entvar ?? ref + '_ent')
  const matchvar = kvar(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const datavar = kvar(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))
  const srcdatavar = kvar(step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  const flowHasCreate = Object.values(flowSteps(flow)).some((s: any) => (s as any).o === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === kvar(preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.o) {
        const priorRef = s.i.ref ?? entity.name + '_ref01'
        const priorDatvar = kvar(s.i.datavar ?? (priorRef + '_data' + (s.i.suffix ?? '')))
        return priorDatvar === srcdatavar
      }
      return false
    })

  const hasEntId = null != entity.id

  Content(`    // LOAD
`)
  if (!hasEntVar) {
    Content(`    val ${entvar} = client.${accessor}(null)
`)
  }
  if (!hasSrcData && hasEntId) {
    Content(`    val ${srcdatavar}Raw = Struct.items(Helpers.toMapAny(
        Struct.getpath(setup.data, "existing.${entity.name}")))
    val ${srcdatavar}: MutableMap<String, Any?> = if (${srcdatavar}Raw.isEmpty())
        linkedMapOf() else (Helpers.toMapAny(${srcdatavar}Raw[0][1]) ?: linkedMapOf())
`)
  }
  Content(`    val ${matchvar} = linkedMapOf<String, Any?>()
`)
  if (hasEntId) {
    Content(`    ${matchvar}["id"] = ${srcdatavar}["id"]
    val ${datavar}Loaded = ${entvar}.load(${matchvar}, null)
    val ${datavar}LoadResult = Helpers.toMapAny(if (${datavar}Loaded is SdkEntity) ${datavar}Loaded.data() else ${datavar}Loaded) ?: linkedMapOf()
    assertNotNull(${datavar}LoadResult, "expected load result to be a map")
    assertEquals(${srcdatavar}["id"], ${datavar}LoadResult["id"],
        "expected load result id to match")
`)
  } else {
    Content(`    val ${datavar}Loaded = ${entvar}.load(${matchvar}, null)
    assertNotNull(${datavar}Loaded, "expected load result to be non-null")
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = kvar(step.i.entvar ?? ref + '_ent')
  const matchvar = kvar(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const srcdatavar = kvar(step.i.srcdatavar ?? (ref + '_data'))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  Content(`    // REMOVE
`)
  if (needsEnt) {
    Content(`    val ${entvar} = client.${accessor}(null)
`)
  }
  Content(`    val ${matchvar} = linkedMapOf<String, Any?>()
    ${matchvar}["id"] = ${srcdatavar}["id"]
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
