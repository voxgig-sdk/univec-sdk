
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


import { javaVarName } from './utility_java'


// Convert snake_case to camelCase for Java variable names.
function javaVar(name: string): string {
  return name.replace(/_([a-z0-9])/g, (_: any, c: string) => c.toUpperCase())
}


// GenCtx mirrors the shared shape (see TestEntity_ts.ts) plus the
// javapackage slot used for the generated package statement.
type GenCtx = {
  model: Model
  entity: ModelEntity
  javapackage: string
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
  const javapackage: string = props.javapackage

  const basicflow: ModelEntityFlow | undefined =
    getModelPath(model, `main.${KIT}.flow.Basic${nom(entity, 'Name')}Flow`)
  if (null == basicflow || true !== basicflow.active) {
    return
  }

  const PROJUPPER = envName(model)
  const ENTUPPER = envToken(entity.name)
  const entidEnvVar = `${PROJUPPER}_TEST_${ENTUPPER}_ENTID`

  const SDK = model.const.Name + 'SDK'
  const accessor = javaVarName(entity.name)

  const authActive = isAuthActive(model)

  const idnames = buildIdNames(entity, basicflow)

  // Get all update data entries for alias generation
  const allSteps = Object.values(basicflow.step) as any[]
  const updateStep = allSteps.find((s: any) => s.op === 'update')
  const updateData = updateStep?.data
    ? Object.entries(updateStep.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  const aliases = updateData.map(([k, v]: any) => [k, v])

  const genCtx: GenCtx = { model, entity, javapackage, flow: basicflow, PROJUPPER, accessor }

  const stepOps = Array.from(new Set(
    (allSteps as any[]).map((s: any) => s.op).filter(Boolean)))

  File({ name: entity.Name + 'EntityTest.' + target.ext }, () => {

    Content(`package ${javapackage}.sdktest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import ${javapackage}.core.Helpers;
import ${javapackage}.core.SdkEntity;
import ${javapackage}.core.${SDK};
import ${javapackage}.utility.Json;
import ${javapackage}.utility.struct.Struct;

@SuppressWarnings({"unchecked", "unused"})
public class ${entity.Name}EntityTest {

  @Test
  public void instance() {
    ${SDK} testsdk = ${SDK}.testSDK();
    SdkEntity ent = testsdk.${accessor}(null);
    assertNotNull(ent, "expected non-null ${entity.name} entity");
  }

  @Test
  public void basic() {
    RunnerSupport.EntityTestSetup setup = ${accessor}BasicSetup(null);
    // Per-op sdk-test-control.json skip — basic test exercises a flow
    // with multiple ops; skipping any op skips the whole flow.
    String mode = setup.live ? "live" : "unit";
    for (String op : new String[] { ${stepOps.map(o => `"${o}"`).join(', ')} }) {
      String reason = RunnerSupport.skipReason("entityOp", "${entity.name}." + op, mode);
      Assumptions.assumeTrue(reason == null,
          reason == null || "".equals(reason)
              ? "skipped via sdk-test-control.json" : reason);
    }
    // The basic flow consumes synthetic IDs from the fixture. In live mode
    // without an *_ENTID env override, those IDs hit the live API and 4xx.
    Assumptions.assumeFalse(setup.syntheticOnly,
        "live entity test uses synthetic IDs from fixture — set ${entidEnvVar} JSON to run live");
${allSteps.length > 0 ? `    ${SDK} client = setup.client;\n\n` : ''}`)

    // Check if the flow has a create step; if not, bootstrap entity data
    const flowHasCreate = allSteps.some((s: any) => s.op === 'create')
    if (!flowHasCreate) {
      const preambleRef = entity.name + '_ref01'
      const preambleVar = javaVar(preambleRef)
      Content(`    // Bootstrap entity data from existing test data (no create step in flow).
    List<List<Object>> ${preambleVar}DataRaw = Struct.items(Helpers.toMapAny(
        Struct.getpath(setup.data, "existing.${entity.name}")));
    Map<String, Object> ${preambleVar}Data = ${preambleVar}DataRaw.isEmpty()
        ? null : Helpers.toMapAny(${preambleVar}DataRaw.get(0).get(1));

`)
    }

    // Model-driven step iteration
    each(basicflow.step, (step: any, index: any) => {
      const opgen: OpGen = GENERATE_OP[step.op]
      if (opgen) {
        opgen(genCtx, step, index)
        Content('\n')
      }
    })

    Content(`  }

`)

    // Stream test (PR #4): the entity `stream` method runs the op pipeline and
    // returns a Stream. With the streaming feature active it yields from the
    // feature's incremental iterator; otherwise it falls back to the
    // materialised items. Only emitted for entities whose flow lists.
    const flowHasList = allSteps.some((s: any) => s.op === 'list')
    if (flowHasList) {
      Content(`  @Test
  public void stream() {
    Map<String, Object> streamingActive = new LinkedHashMap<>();
    Map<String, Object> streamingOpts = new LinkedHashMap<>();
    streamingOpts.put("active", true);
    Map<String, Object> featureOpts = new LinkedHashMap<>();
    featureOpts.put("streaming", streamingOpts);
    streamingActive.put("feature", featureOpts);

    RunnerSupport.EntityTestSetup setup = ${accessor}BasicSetup(streamingActive);
    Assumptions.assumeFalse(setup.live,
        "stream test streams the seeded fixture data (unit mode only)");

    SdkEntity ent = setup.client.${accessor}(null);
    Map<String, Object> match = new LinkedHashMap<>();

    // Materialised list result for the same op.
    Object listedResult = ent.list(match, null);
    List<Object> listed = listedResult instanceof List
        ? (List<Object>) listedResult : new ArrayList<>();

    // stream("list") yields items via the streaming feature's iterator.
    List<Object> streamed = ent.stream("list", match, null)
        .collect(Collectors.toList());
    assertTrue(streamed.size() > 0, "expected stream to yield items");
    assertEquals(listed.size(), streamed.size(),
        "expected stream to yield the same item count as list");

    // Fallback: with streaming inactive, stream still yields the
    // materialised items.
    RunnerSupport.EntityTestSetup setup2 = ${accessor}BasicSetup(null);
    SdkEntity ent2 = setup2.client.${accessor}(null);
    List<Object> streamed2 = ent2.stream("list", match, null)
        .collect(Collectors.toList());
    assertEquals(listed.size(), streamed2.size(),
        "expected fallback stream to yield the materialised items");
  }

`)
    }

    // Generate setup function
    Content(`  static RunnerSupport.EntityTestSetup ${accessor}BasicSetup(Map<String, Object> extra) {
    RunnerSupport.loadEnvLocal();

    Map<String, Object> entityData;
    try {
      String entityDataSource = Files.readString(Path.of(
          "..", ".sdk", "test", "entity", "${entity.name}", "${entity.Name}TestData.json"));
      entityData = Helpers.toMapAny(Json.parse(entityDataSource));
    }
    catch (Exception e) {
      throw new AssertionError("failed to read ${entity.name} test data: " + e.getMessage(), e);
    }

    Map<String, Object> options = new LinkedHashMap<>();
    options.put("entity", entityData.get("existing"));

    ${SDK} client = ${SDK}.testSDK(options, extra);

    // Generate idmap via transform, matching TS pattern.
    List<Object> idnames = new ArrayList<>();
`)

    for (const n of idnames) {
      Content(`    idnames.add("${n}");
`)
    }

    Content(`    Object idmap = Struct.transform(idnames, Json.parse(
        "{\\"\`$PACK\`\\": [\\"\\", {"
        + "\\"\`$KEY\`\\": \\"\`$COPY\`\\","
        + "\\"\`$VAL\`\\": [\\"\`$FORMAT\`\\", \\"upper\\", \\"\`$COPY\`\\"]"
        + "}]}"));

    // Detect ENTID env override before envOverride consumes it. When live
    // mode is on without a real override, the basic test runs against
    // synthetic IDs from the fixture and 4xx's. Surface this so the test
    // can skip.
    String entidEnvRaw = RunnerSupport.getenv("${entidEnvVar}");
    boolean idmapOverridden = entidEnvRaw != null
        && entidEnvRaw.trim().startsWith("{");

    Map<String, Object> envm = new LinkedHashMap<>();
    envm.put("${entidEnvVar}", idmap);
    envm.put("${PROJUPPER}_TEST_LIVE", "FALSE");
    envm.put("${PROJUPPER}_TEST_EXPLAIN", "FALSE");
${authActive ? `    envm.put("${PROJUPPER}_APIKEY", "NONE");\n` : ''}    Map<String, Object> env = RunnerSupport.envOverride(envm);

    Map<String, Object> idmapResolved = Helpers.toMapAny(env.get("${entidEnvVar}"));
    if (idmapResolved == null) {
      idmapResolved = Helpers.toMapAny(idmap);
    }
`)

    // Add aliases for ancestor field names
    for (const [key, val] of aliases) {
      Content(`    // Add ${key} alias for update test.
    if (idmapResolved.get("${key}") == null) {
      idmapResolved.put("${key}", idmapResolved.get("${val}"));
    }
`)
    }

    Content(`
    boolean live = "TRUE".equals(env.get("${PROJUPPER}_TEST_LIVE"));
    if (live) {
      Map<String, Object> liveOpts = new LinkedHashMap<>();
${authActive ? `      liveOpts.put("apikey", env.get("${PROJUPPER}_APIKEY"));\n` : ''}      Object mergedOpts = Struct.merge(Struct.jt(liveOpts, extra));
      client = new ${SDK}(Helpers.toMapAny(mergedOpts));
    }

    RunnerSupport.EntityTestSetup setup = new RunnerSupport.EntityTestSetup();
    setup.client = client;
    setup.data = entityData;
    setup.idmap = idmapResolved;
    setup.env = env;
    setup.explain = "TRUE".equals(env.get("${PROJUPPER}_TEST_EXPLAIN"));
    setup.live = live;
    setup.syntheticOnly = live && !idmapOverridden;
    setup.now = System.currentTimeMillis();
    return setup;
  }
}
`)
  })
})


const generateCreate: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.input.entvar ?? ref + '_ent')
  const datavar = javaVar(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const hasDatvar = priorSteps.some((s: any) => {
    if ('create' === s.op) {
      const priorRef = s.input.ref ?? entity.name + '_ref01'
      const priorDatvar = javaVar(s.input.datavar ?? (priorRef + '_data' + (s.input.suffix ?? '')))
      return priorDatvar === datavar
    }
    return false
  })

  Content(`    // CREATE
`)
  if (needsEnt) {
    Content(`    SdkEntity ${entvar} = client.${accessor}(null);
`)
  }

  // Load data from test data file
  const decl = hasDatvar ? '' : 'Map<String, Object> '
  Content(`    ${decl}${datavar} = Helpers.toMapAny(Struct.getprop(
        Struct.getpath(setup.data, "new.${entity.name}"), "${ref}"));
`)

  // Add match entries
  const matchEntries = getMatchEntries(step)
  for (const [key, val] of matchEntries) {
    Content(`    ${datavar}.put("${key}", setup.idmap.get("${val}"));
`)
  }

  Content(`
    Object ${datavar}Result = ${entvar}.create(${datavar}, null);
    ${datavar} = Helpers.toMapAny(${datavar}Result instanceof SdkEntity ? ((SdkEntity) ${datavar}Result).data() : ${datavar}Result);
    assertNotNull(${datavar}, "expected create result to be a map");
`)
  if (null != ctx.entity.id) {
    Content(`    assertNotNull(${datavar}.get("id"), "expected created entity to have an id");
`)
  }
}


const generateList: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.input.entvar ?? ref + '_ent')
  const matchvar = javaVar(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const listvar = javaVar(step.input.listvar ?? (ref + '_list' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`    // LIST
`)
  if (needsEnt) {
    Content(`    SdkEntity ${entvar} = client.${accessor}(null);
`)
  }

  // Generate match map
  const matchEntries = getMatchEntries(step)
  Content(`    Map<String, Object> ${matchvar} = new LinkedHashMap<>();
`)
  for (const [key, val] of matchEntries) {
    Content(`    ${matchvar}.put("${key}", setup.idmap.get("${val}"));
`)
  }

  // Only declare ${listvar} as a real var when a downstream validator
  // actually uses it.
  const allSteps = Object.values(flow.step) as any[]
  const listvarUsed = !!step.valid?.some((v: any) => {
    if ('ItemExists' !== v.apply && 'ItemNotExists' !== v.apply) return false
    const validRef = v.def?.ref
    return validRef && allSteps.some((s: any) => 'create' === s.op &&
      ((s.input.ref ?? entity.name + '_ref01') === validRef))
  })

  Content(`
    Object ${listvar}Result = ${entvar}.list(${matchvar}, null);
    assertTrue(${listvar}Result instanceof List,
        "expected list result to be an array, got " + ${listvar}Result);
`)
  if (listvarUsed) {
    Content(`    List<Object> ${listvar} = (List<Object>) ${listvar}Result;
`)
  }

  // Handle validators from step.valid
  if (step.valid) {
    for (const validator of step.valid) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.op &&
        ((s.input.ref ?? entity.name + '_ref01') === validRef))

      if ('ItemExists' === validator.apply && hasRefData) {
        const refDataVar = javaVar(validRef + '_data')
        Content(`
    List<Object> foundItem = Struct.select(
        RunnerSupport.entityListToData(${listvar}),
        Struct.jm("id", ${refDataVar}.get("id")));
    assertFalse(Struct.isempty(foundItem), "expected to find created entity in list");
`)
      } else if ('ItemNotExists' === validator.apply && hasRefData) {
        const refDataVar = javaVar(validRef + '_data')
        Content(`
    List<Object> notFoundItem = Struct.select(
        RunnerSupport.entityListToData(${listvar}),
        Struct.jm("id", ${refDataVar}.get("id")));
    assertTrue(Struct.isempty(notFoundItem), "expected removed entity to not be in list");
`)
      }
    }
  }
}


const generateUpdate: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.input.entvar ?? ref + '_ent')
  const datavar = javaVar(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))
  const resdatavar = javaVar(step.input.resdatavar ?? (ref + '_resdata' + (step.input.suffix ?? '')))
  const markdefvar = javaVar(step.input.markdefvar ?? (ref + '_markdef' + (step.input.suffix ?? '')))
  const srcdatavar = javaVar(step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const hasEntIdU = null != entity.id

  Content(`    // UPDATE
`)
  if (needsEnt) {
    Content(`    SdkEntity ${entvar} = client.${accessor}(null);
`)
  }
  Content(`    Map<String, Object> ${datavar}Up = new LinkedHashMap<>();
`)
  if (hasEntIdU) {
    Content(`    ${datavar}Up.put("id", ${srcdatavar}.get("id"));
`)
  }

  // Add data entries from step.data
  if (step.data) {
    const dataEntries = Object.entries(step.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`    ${datavar}Up.put("${key}", setup.idmap.get("${key}"));
`)
    }
  }

  // Handle TextFieldMark spec
  if (step.spec) {
    for (const spec of step.spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        const fieldname = step.input.textfield
        const fieldvalue = spec.def?.mark ?? `Mark01-${ref}`
        Content(`
    String ${markdefvar}Name = "${fieldname}";
    String ${markdefvar}Value = "${fieldvalue}_" + setup.now;
    ${datavar}Up.put(${markdefvar}Name, ${markdefvar}Value);
`)
      }
    }
  }

  Content(`
    Object ${resdatavar}Result = ${entvar}.update(${datavar}Up, null);
    Map<String, Object> ${resdatavar} = Helpers.toMapAny(${resdatavar}Result instanceof SdkEntity ? ((SdkEntity) ${resdatavar}Result).data() : ${resdatavar}Result);
    assertNotNull(${resdatavar}, "expected update result to be a map");
`)
  if (hasEntIdU) {
    Content(`    assertEquals(${datavar}Up.get("id"), ${resdatavar}.get("id"),
        "expected update result id to match");
`)
  }

  // Assert TextFieldMark
  if (step.spec) {
    for (const spec of step.spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        Content(`    assertEquals(${markdefvar}Value, ${resdatavar}.get(${markdefvar}Name),
        "expected " + ${markdefvar}Name + " to be updated");
`)
      }
    }
  }
}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.input.entvar ?? ref + '_ent')
  const matchvar = javaVar(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const datavar = javaVar(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))
  const srcdatavar = javaVar(step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  // Check if srcdatavar was declared by a prior create step or preamble
  const flowHasCreate = Object.values(flow.step).some((s: any) => (s as any).op === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === javaVar(preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.op) {
        const priorRef = s.input.ref ?? entity.name + '_ref01'
        const priorDatvar = javaVar(s.input.datavar ?? (priorRef + '_data' + (s.input.suffix ?? '')))
        return priorDatvar === srcdatavar
      }
      return false
    })

  const hasEntId = null != entity.id

  Content(`    // LOAD
`)
  if (!hasEntVar) {
    Content(`    SdkEntity ${entvar} = client.${accessor}(null);
`)
  }
  if (!hasSrcData && hasEntId) {
    Content(`    List<List<Object>> ${srcdatavar}Raw = Struct.items(Helpers.toMapAny(
        Struct.getpath(setup.data, "existing.${entity.name}")));
    Map<String, Object> ${srcdatavar} = ${srcdatavar}Raw.isEmpty()
        ? null : Helpers.toMapAny(${srcdatavar}Raw.get(0).get(1));
`)
  }
  Content(`    Map<String, Object> ${matchvar} = new LinkedHashMap<>();
`)
  if (hasEntId) {
    Content(`    ${matchvar}.put("id", ${srcdatavar}.get("id"));
    Object ${datavar}Loaded = ${entvar}.load(${matchvar}, null);
    Map<String, Object> ${datavar}LoadResult = Helpers.toMapAny(${datavar}Loaded instanceof SdkEntity ? ((SdkEntity) ${datavar}Loaded).data() : ${datavar}Loaded);
    assertNotNull(${datavar}LoadResult, "expected load result to be a map");
    assertEquals(${srcdatavar}.get("id"), ${datavar}LoadResult.get("id"),
        "expected load result id to match");
`)
  }
  else {
    Content(`    Object ${datavar}Loaded = ${entvar}.load(${matchvar}, null);
    assertNotNull(${datavar}Loaded, "expected load result to be non-null");
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.input.entvar ?? ref + '_ent')
  const matchvar = javaVar(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const srcdatavar = javaVar(step.input.srcdatavar ?? (ref + '_data'))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`    // REMOVE
`)
  if (needsEnt) {
    Content(`    SdkEntity ${entvar} = client.${accessor}(null);
`)
  }
  // Always match the prior-created entity by id to avoid mock-order flakes.
  Content(`    Map<String, Object> ${matchvar} = new LinkedHashMap<>();
    ${matchvar}.put("id", ${srcdatavar}.get("id"));
    ${entvar}.remove(${matchvar}, null);
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
