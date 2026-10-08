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
  isAuthActive,
  serverVarEnv,
  serverVariables, envName, envToken,
  liveFlowNeeds, liveStrict, liveStrictNote,
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


// The live prologue of a flow built from offline fixtures: blocked without
// the ids it binds, a create-less load reading the first listed record, and
// a lenient run observing its checks rather than failing on them.
function liveFlowGate(entity: any, needs: any, entidEnv: string, accessor: string,
  SDK: string, strict: boolean, hasSteps: boolean): string {
  let out = ''
  if (0 < needs.keys.length) {
    out += `    if (setup.live) {
      for (String liveKey : new String[] { ${needs.keys.map((k: string) => JSON.stringify(k)).join(', ')} }) {
        if (setup.syntheticOnly || setup.idmap.get(liveKey) == null) {
          RunnerSupport.liveMiss(LIVE_STRICT, "Live entity test blocked: needs " + liveKey + " via ${entidEnv}");
        }
      }
    }
`
  }
  if (null != needs.blocked) {
    out += `    if (setup.live) {
      RunnerSupport.liveMiss(LIVE_STRICT, "Live entity test blocked: " + ${JSON.stringify(needs.blocked)});
    }
`
  }
  if (!hasSteps) {
    return out
  }
  out += `    ${SDK} client = setup.client;\n`
  if (null != needs.discover) {
    const match = Object.entries(needs.discover)
      .map(([k, v]: any) => `match.put(${JSON.stringify(k)}, setup.idmap.get(${JSON.stringify(v)}));`).join(' ')
    out += `    if (setup.live) {
      RunnerSupport.liveExisting(setup.data, LIVE_STRICT, ${JSON.stringify(entity.name)}, () -> {
        Map<String, Object> match = new LinkedHashMap<>();${match ? ' ' + match : ''}
        return client.${accessor}(null).list(match, null);
      });
    }
`
  }
  if (!strict) {
    out += '    try {\n'
  }
  return out + '\n'
}


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


  // A templated server URL (OpenAPI server variables) makes a LIVE client
  // impossible to construct without values: MakeOptions throws rather than
  // request a URL with a literal `{account_id}` in it. Taken from the
  // environment, the same way the apikey is.
  const svars = serverVariables(model)
  const serverEnvEntry = svars
    .map((v: any) => `    envm.put("${serverVarEnv(PROJUPPER, v.name)}", ${JSON.stringify(v.dflt)});\n`).join('')
  const serverLiveField = 0 === svars.length ? '' :
    `      Map<String, Object> serveropt = new LinkedHashMap<>();\n` +
    svars.map((v: any) =>
      `      serveropt.put("${v.name}", env.get("${serverVarEnv(PROJUPPER, v.name)}"));\n`).join('') +
    `      liveOpts.put("server", serveropt);\n`

  const idnames = buildIdNames(entity, basicflow)

  // Get all update data entries for alias generation
  const allSteps = Object.values(flowSteps(basicflow)) as any[]
  const updateStep = allSteps.find((s: any) => s.o === 'update')
  const updateData = updateStep?.d
    ? Object.entries(updateStep.d).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  const aliases = updateData.map(([k, v]: any) => [k, v])

  const genCtx: GenCtx = { model, entity, javapackage, flow: basicflow, PROJUPPER, accessor }

  const strict = liveStrict(model, target.name)
  const needs = liveFlowNeeds(entity, basicflow)

  const stepOps = Array.from(new Set(
    (allSteps as any[]).map((s: any) => s.o).filter(Boolean)))

  File({ name: entity.Name + 'EntityTest.' + target.ext }, () => {

    Content(`package ${javapackage}.sdktest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
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

import ${javapackage}.core.Config;
import ${javapackage}.core.Context;
import ${javapackage}.core.Helpers;
import ${javapackage}.core.SdkEntity;
import ${javapackage}.core.SdkError;
import ${javapackage}.core.${SDK};
import ${javapackage}.feature.BaseFeature;
import ${javapackage}.utility.Json;
import ${javapackage}.utility.struct.Struct;

@SuppressWarnings({"unchecked", "unused"})
public class ${entity.Name}EntityTest {

${liveStrictNote(strict, '//', '  ')}
  static final boolean LIVE_STRICT = ${strict};

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
${liveFlowGate(entity, needs, entidEnvVar, accessor, SDK, strict, allSteps.length > 0)}`)

    // Check if the flow has a create step; if not, bootstrap entity data
    const flowHasCreate = allSteps.some((s: any) => s.o === 'create')
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
    each(flowSteps(basicflow), (step: any, index: any) => {
      const opgen: OpGen = GENERATE_OP[step.o]
      if (opgen) {
        opgen(genCtx, step, index)
        Content('\n')
      }
    })

    Content(`${strict || 0 === allSteps.length ? '' : `    }
    catch (Throwable err) {
      RunnerSupport.liveObserve(err, setup.live, LIVE_STRICT);
    }
`}  }

`)

    // The stream test lists with no match, so a bare call must reach a route.
    const flowHasList = allSteps.some((s: any) => s.o === 'list') &&
      opReachable((entity.op as any)?.list, [])
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

    const hasList = opReachable((entity.op as any)?.list, [])
    Content(failureTests(SDK, entity, accessor, hasList))

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

    // Whether *_ENTID supplied the idmap, read before envOverride consumes
    // it: without it, the ids a live flow binds are the fixture's synthetic ones.
    String entidEnvRaw = RunnerSupport.getenv("${entidEnvVar}");
    boolean idmapOverridden = entidEnvRaw != null
        && entidEnvRaw.trim().startsWith("{");

    Map<String, Object> envm = new LinkedHashMap<>();
    envm.put("${entidEnvVar}", idmap);
    envm.put("${PROJUPPER}_TEST_LIVE", "FALSE");
    envm.put("${PROJUPPER}_TEST_EXPLAIN", "FALSE");
${authActive ? `    envm.put("${PROJUPPER}_APIKEY", "");\n` : ''}${serverEnvEntry}    Map<String, Object> env = RunnerSupport.envOverride(envm);

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
      // sdk-test-control.json's test.client.options seeds the live
      // client; the generated fields below overwrite anything they name.
      Map<String, Object> liveOpts =
          new LinkedHashMap<>(RunnerSupport.liveClientOptions());
${authActive ? `      liveOpts.put("apikey", env.get("${PROJUPPER}_APIKEY"));\n` : ''}${serverLiveField}      // An empty map, not a null one: merge answers null when its last
      // entry is null, and basicSetup is normally called with no extras -
      // so a bare null silently discarded the apikey and server values
      // above.
      Map<String, Object> extraOpts =
          extra == null ? new LinkedHashMap<>() : extra;
      Object mergedOpts = Struct.merge(Struct.jt(liveOpts, extraOpts));
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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.i.entvar ?? ref + '_ent')
  const datavar = javaVar(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  const hasDatvar = priorSteps.some((s: any) => {
    if ('create' === s.o) {
      const priorRef = s.i.ref ?? entity.name + '_ref01'
      const priorDatvar = javaVar(s.i.datavar ?? (priorRef + '_data' + (s.i.suffix ?? '')))
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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.i.entvar ?? ref + '_ent')
  const matchvar = javaVar(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const listvar = javaVar(step.i.listvar ?? (ref + '_list' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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
  const allSteps = Object.values(flowSteps(flow)) as any[]
  const listvarUsed = !!step.v?.some((v: any) => {
    if ('ItemExists' !== v.apply && 'ItemNotExists' !== v.apply) return false
    const validRef = v.def?.ref
    return validRef && allSteps.some((s: any) => 'create' === s.o &&
      ((s.i.ref ?? entity.name + '_ref01') === validRef))
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

  // Handle validators from step.v
  if (step.v) {
    for (const validator of step.v) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.o &&
        ((s.i.ref ?? entity.name + '_ref01') === validRef))

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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.i.entvar ?? ref + '_ent')
  const datavar = javaVar(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))
  const resdatavar = javaVar(step.i.resdatavar ?? (ref + '_resdata' + (step.i.suffix ?? '')))
  const markdefvar = javaVar(step.i.markdefvar ?? (ref + '_markdef' + (step.i.suffix ?? '')))
  const srcdatavar = javaVar(step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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

  // Add data entries from step.d
  if (step.d) {
    const dataEntries = Object.entries(step.d).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`    ${datavar}Up.put("${key}", setup.idmap.get("${key}"));
`)
    }
  }

  // Handle TextFieldMark spec
  if (step.s) {
    for (const spec of step.s) {
      if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
        const fieldname = step.i.textfield
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
  if (step.s) {
    for (const spec of step.s) {
      if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
        Content(`    assertEquals(${markdefvar}Value, ${resdatavar}.get(${markdefvar}Name),
        "expected " + ${markdefvar}Name + " to be updated");
`)
      }
    }
  }
}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow, accessor } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.i.entvar ?? ref + '_ent')
  const matchvar = javaVar(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const datavar = javaVar(step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? '')))
  const srcdatavar = javaVar(step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? '')))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  // Check if srcdatavar was declared by a prior create step or preamble
  const flowHasCreate = Object.values(flowSteps(flow)).some((s: any) => (s as any).o === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === javaVar(preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.o) {
        const priorRef = s.i.ref ?? entity.name + '_ref01'
        const priorDatvar = javaVar(s.i.datavar ?? (priorRef + '_data' + (s.i.suffix ?? '')))
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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = javaVar(step.i.entvar ?? ref + '_ent')
  const matchvar = javaVar(step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? '')))
  const srcdatavar = javaVar(step.i.srcdatavar ?? (ref + '_data'))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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


// A failed operation throws from a stream as it does from the operation: a
// transport failure, and a hook that rejects the call. A throwing hook fires
// PreUnexpected, under throw false too. The caller's ctrl stays its own. An
// invalid request fails with validate's own error, before it is sent.
function failureTests(SDK: string, entity: ModelEntity, accessor: string, hasList: boolean): string {
  const bad = invalidRequest(entity)
  if (!hasList && null == bad) {
    return ''
  }

  let out = `  static boolean hasFeature(String name) {
    Map<String, Object> fm = Helpers.toMapAny(Config.makeConfig().get("feature"));
    return fm != null && fm.get(name) != null;
  }

`

  if (hasList) {
    out += `  public static final class FailHook extends BaseFeature {
    int unexpected = 0;

    FailHook() {
      super("failhook", "0.0.1", true);
    }

    @Override
    public void preSpec(Context ctx) {
      throw new RuntimeException("${entity.name} hook failed");
    }

    @Override
    public void preUnexpected(Context ctx) {
      this.unexpected++;
    }
  }

  @Test
  public void streamError() {
    Map<String, Object> offline = Struct.jm("net", Struct.jm("offline", true));
    RuntimeException err = assertThrows(RuntimeException.class, () ->
        ${SDK}.testSDK(offline, null).${accessor}(null).stream("list", null, null)
            .collect(Collectors.toList()));
    assertTrue(err.getMessage().contains("offline"), err.getMessage());

    ${SDK}.testSDK(offline, null).${accessor}(null)
        .stream("list", null, Struct.jm("ctrl", Struct.jm("throw", false)))
        .collect(Collectors.toList());

    if (hasFeature("rbac")) {
      ${SDK} denied = ${SDK}.testSDK(null,
          Struct.jm("feature", Struct.jm("rbac", Struct.jm("active", true, "deny", true))));
      SdkError denyerr = assertThrows(SdkError.class, () ->
          denied.${accessor}(null).stream("list", null, null).collect(Collectors.toList()));
      assertEquals("rbac_denied", denyerr.code);
    }
  }

  @Test
  public void streamCtrl() {
    Map<String, Object> explain = new LinkedHashMap<>();
    Map<String, Object> ctrl = new LinkedHashMap<>();
    ctrl.put("explain", explain);
    ${SDK}.testSDK().${accessor}(null).stream("list", null, Struct.jm("ctrl", ctrl))
        .collect(Collectors.toList());
    assertEquals(List.of("explain"), new ArrayList<>(ctrl.keySet()));
    assertTrue(explain == ctrl.get("explain") && !explain.isEmpty());
  }

  @Test
  public void unexpected() {
    FailHook hook = new FailHook();
    ${SDK} client = new ${SDK}(Struct.jm(
        "feature", Struct.jm("test", Struct.jm("active", true)),
        "extend", Struct.jt(hook)));

    RuntimeException err = assertThrows(RuntimeException.class, () ->
        client.${accessor}(null).list(null, null));
    assertTrue(err.getMessage().contains("hook failed"), err.getMessage());
    assertTrue(0 < hook.unexpected);

    int fired = hook.unexpected;
    client.${accessor}(null).list(null, Struct.jm("throw", false));
    assertTrue(fired < hook.unexpected);
  }

`
  }

  if (null != bad) {
    const args = Object.entries(bad.args)
      .map(([k, v]) => JSON.stringify(k) + ', ' + JSON.stringify(v)).join(', ')
    out += `  @Test
  public void validate() {
    Assumptions.assumeTrue(hasFeature("validate"), "feature not present in this SDK: validate");
    ${SDK} client = ${SDK}.testSDK(null,
        Struct.jm("feature", Struct.jm("validate", Struct.jm("active", true))));
    SdkError err = assertThrows(SdkError.class, () ->
        client.${accessor}(null).${bad.op}(Struct.jm(${args}), null));
    assertEquals("validate_failed", err.code);
  }

`
  }

  return out
}


export {
  TestEntity
}
