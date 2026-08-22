
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


import { csVarName } from './utility_csharp'


// Convert a model name to a camelCase C# local (planet_ref01 -> planetRef01).
function csVar(name: string): string {
  return csVarName(name)
}


type GenCtx = {
  model: Model
  entity: ModelEntity
  flow: ModelEntityFlow
  PROJUPPER: string
}

type OpGen = (ctx: GenCtx, step: ModelEntityFlowStep, index: number) => void


const TestEntity = cmp(function TestEntity(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity

  const basicflow: ModelEntityFlow | undefined =
    getModelPath(model, `main.${KIT}.flow.Basic${nom(entity, 'Name')}Flow`)
  if (null == basicflow || true !== basicflow.active) {
    return
  }

  const Name = model.const.Name
  const PROJUPPER = envName(model)
  const ENTUPPER = envToken(entity.name)

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n            ["${PROJUPPER}_APIKEY"] = "NONE",`
    : ''
  const apikeyLiveField = authActive
    ? `\n                    ["apikey"] = env["${PROJUPPER}_APIKEY"],`
    : ''

  const idnames = buildIdNames(entity, basicflow)
  const idnamesStr = idnames.map(n => `"${n}"`).join(', ')

  // Get all update data entries for alias generation
  const allSteps = Object.values(basicflow.step) as any[]
  const updateStep = allSteps.find((s: any) => s.op === 'update')
  const updateData = updateStep?.data
    ? Object.entries(updateStep.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  const aliases = updateData.map(([k, v]: any) => [k, v])

  const genCtx: GenCtx = { model, entity, flow: basicflow, PROJUPPER }

  const opNames = Array.from(new Set(
    (allSteps as any[]).map((s: any) => s.op).filter(Boolean)))
  const opsList = opNames.map(o => `"${o}"`).join(', ')

  // An entity whose basic flow has no ops must not emit the per-op skip
  // loop. `new[] { }` is an empty implicitly-typed array and C# cannot infer
  // its element type — CS0826, which fails the whole test project to build.
  // The loop is dead code in that case anyway, and so is the `_mode` local
  // that only it reads (CS0219 unused-variable otherwise).
  const skipBlock = 0 === opNames.length ? '' : `        // Per-op sdk-test-control.json skip - basic test exercises a flow
        // with multiple ops; skipping any op skips the whole flow.
        var _mode = setup.Live ? "live" : "unit";
        foreach (var _op in new[] { ${opsList} })
        {
            var (_shouldSkip, _) = TestRunner.IsControlSkipped(
                "entityOp", "${entity.name}." + _op, _mode);
            if (_shouldSkip)
            {
                return; // skipped via sdk-test-control.json
            }
        }
`

  File({ name: entity.Name + 'EntityTest.' + target.ext }, () => {

    Content(`// ${entity.name} entity test - basic flow (generated from the API model).

using System.Text.Json;

using Voxgig.Struct;
using Xunit;

namespace ${Name}Sdk.Test;

public class ${entity.Name}EntityTest
{
    [Fact]
    public void Instance()
    {
        var testsdk = ${Name}SDK.TestSDK(null, null);
        var ent = testsdk.${entity.Name}();
        Assert.NotNull(ent);
    }

    [Fact]
    public void Basic()
    {
        var setup = ${entity.Name}BasicSetup(null);
${skipBlock}        // The basic flow consumes synthetic IDs from the fixture. In live
        // mode without an *_ENTID env override, those IDs hit the live API
        // and 4xx; set ${PROJUPPER}_TEST_${ENTUPPER}_ENTID JSON to run live.
        if (setup.SyntheticOnly)
        {
            return;
        }
${allSteps.length > 0 ? '        var client = setup.Client;\n\n' : ''}`)

    // Check if the flow has a create step; if not, bootstrap entity data
    const flowHasCreate = allSteps.some((s: any) => s.op === 'create')
    if (!flowHasCreate) {
      const preambleRef = entity.name + '_ref01'
      const preambleVar = csVar(preambleRef)
      Content(`        // Bootstrap entity data from existing test data (no create step in flow).
        var ${preambleVar}DataRaw = StructUtils.Items(
            Helpers.ToMapAny(StructUtils.GetPath(setup.Data, "existing.${entity.name}")));
        var ${preambleVar}Data = ${preambleVar}DataRaw.Count > 0
            ? Helpers.ToMapAny(${preambleVar}DataRaw[0][1])
            : null;

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

    Content(`    }

`)

    // Stream test (PR #4): the entity `stream` method runs the op pipeline and
    // returns an async iterator. With the streaming feature active it yields
    // from the feature's incremental iterator; otherwise it falls back to the
    // materialised items. Only emitted for entities whose flow lists.
    const flowHasList = allSteps.some((s: any) => s.op === 'list')
    if (flowHasList) {
      Content(`    [Fact]
    public async Task Stream()
    {
        var setup = ${entity.Name}BasicSetup(new Dictionary<string, object?>
        {
            ["feature"] = new Dictionary<string, object?>
            {
                ["streaming"] = new Dictionary<string, object?> { ["active"] = true },
            },
        });
        if (setup.Live)
        {
            return; // unit mode only - streams the seeded fixture data
        }

        var ent = setup.Client.${entity.Name}();
        var match = new Dictionary<string, object?>();

        // Materialised list result for the same op.
        var listed = ent.List(match, null) as List<object?> ?? new List<object?>();

        // stream("list") yields items via the streaming feature's iterator.
        var streamed = new List<object?>();
        await foreach (var item in ent.Stream("list", match, null))
        {
            streamed.Add(item);
        }
        Assert.True(streamed.Count > 0, "expected stream to yield items");
        Assert.Equal(listed.Count, streamed.Count);

        // Fallback: with streaming inactive, stream still yields the
        // materialised items.
        var setup2 = ${entity.Name}BasicSetup(null);
        var ent2 = setup2.Client.${entity.Name}();
        var streamed2 = new List<object?>();
        await foreach (var item in ent2.Stream("list", match, null))
        {
            streamed2.Add(item);
        }
        Assert.Equal(listed.Count, streamed2.Count);
    }

`)
    }

    // Generate setup function
    Content(`    private static EntityTestSetup ${entity.Name}BasicSetup(
        Dictionary<string, object?>? extra)
    {
        TestRunner.LoadEnvLocal();

        var entityDataFile = Path.Combine(TestRunner.TestDir(),
            "..", "..", ".sdk", "test", "entity", "${entity.name}",
            "${entity.Name}TestData.json");

        var entityDataEl = JsonSerializer.Deserialize<JsonElement>(
            File.ReadAllText(entityDataFile));
        var entityData = StructRunner.ConvertElement(entityDataEl)
            as Dictionary<string, object?>
            ?? throw new InvalidOperationException(
                "failed to parse ${entity.name} test data");

        var options = new Dictionary<string, object?>
        {
            ["entity"] = entityData["existing"],
        };

        var client = ${Name}SDK.TestSDK(options, extra);

        // Generate idmap via transform, matching the TS pattern.
        var idmap = StructUtils.Transform(
            new List<object?> { ${idnamesStr} },
            new Dictionary<string, object?>
            {
                ["\`$PACK\`"] = new List<object?>
                {
                    "",
                    new Dictionary<string, object?>
                    {
                        ["\`$KEY\`"] = "\`$COPY\`",
                        ["\`$VAL\`"] = new List<object?> { "\`$FORMAT\`", "upper", "\`$COPY\`" },
                    },
                },
            });

        // Detect ENTID env override before EnvOverride consumes it. When
        // live mode is on without a real override, the basic test runs
        // against synthetic IDs from the fixture and 4xx's.
        var entidEnvRaw = Environment.GetEnvironmentVariable(
            "${PROJUPPER}_TEST_${ENTUPPER}_ENTID") ?? "";
        var idmapOverridden = entidEnvRaw != "" &&
            entidEnvRaw.Trim().StartsWith("{");

        var env = TestRunner.EnvOverride(new Dictionary<string, object?>
        {
            ["${PROJUPPER}_TEST_${ENTUPPER}_ENTID"] = idmap,
            ["${PROJUPPER}_TEST_LIVE"] = "FALSE",
            ["${PROJUPPER}_TEST_EXPLAIN"] = "FALSE",${apikeyEnvEntry}
        });

        var idmapResolved = Helpers.ToMapAny(env["${PROJUPPER}_TEST_${ENTUPPER}_ENTID"])
            ?? Helpers.ToMapAny(idmap)
            ?? new Dictionary<string, object?>();
`)

    // Add aliases for ancestor field names
    for (const [key, val] of aliases) {
      Content(`
        // Add ${key} alias for the update test.
        if (StructUtils.GetProp(idmapResolved, "${key}") == null)
        {
            idmapResolved["${key}"] = StructUtils.GetProp(idmapResolved, "${val}");
        }
`)
    }

    Content(`
        if (Equals(env["${PROJUPPER}_TEST_LIVE"], "TRUE"))
        {
            var mergedOpts = StructUtils.Merge(new List<object?>
            {
                new Dictionary<string, object?>
                {${apikeyLiveField}
                },
                extra,
            });
            client = new ${Name}SDK(Helpers.ToMapAny(mergedOpts));
        }

        var live = Equals(env["${PROJUPPER}_TEST_LIVE"], "TRUE");
        return new EntityTestSetup
        {
            Client = client,
            Data = entityData,
            Idmap = idmapResolved,
            Env = env,
            Explain = Equals(env["${PROJUPPER}_TEST_EXPLAIN"], "TRUE"),
            Live = live,
            SyntheticOnly = live && !idmapOverridden,
            Now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        };
    }
}
`)
  })
})


const generateCreate: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = csVar(step.input.entvar ?? ref + '_ent')
  const datavar = csVar(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const hasDatvar = priorSteps.some((s: any) => {
    if ('create' === s.op) {
      const priorRef = s.input.ref ?? entity.name + '_ref01'
      const priorDatvar = csVar(s.input.datavar ?? (priorRef + '_data' + (s.input.suffix ?? '')))
      return priorDatvar === datavar
    }
    return false
  })

  Content(`        // CREATE
`)
  if (needsEnt) {
    Content(`        var ${entvar} = client.${entity.Name}();
`)
  }

  // Load data from test data file
  Content(`        ${hasDatvar ? '' : 'var '}${datavar} = Helpers.ToMapAny(StructUtils.GetProp(
            StructUtils.GetPath(setup.Data, StructUtils.Jt("new", "${entity.name}")),
            "${ref}"));
`)

  // Add match entries
  const matchEntries = getMatchEntries(step)
  for (const [key, val] of matchEntries) {
    Content(`        ${datavar}!["${key}"] = setup.Idmap["${val}"];
`)
  }

  Content(`
        var ${datavar}Result = ${entvar}.Create(${datavar}, null);
        ${datavar} = Helpers.ToMapAny(${datavar}Result is IEntity ce ? ce.Data() : ${datavar}Result);
        Assert.True(${datavar} != null, "expected create result to be a map");
`)
  if (null != ctx.entity.id) {
    Content(`        Assert.True(${datavar}!["id"] != null, "expected created entity to have an id");
`)
  }
}


const generateList: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = csVar(step.input.entvar ?? ref + '_ent')
  const matchvar = csVar(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const listvar = csVar(step.input.listvar ?? (ref + '_list' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`        // LIST
`)
  if (needsEnt) {
    Content(`        var ${entvar} = client.${entity.Name}();
`)
  }

  // Generate match map
  const matchEntries = getMatchEntries(step)
  if (matchEntries.length === 0) {
    Content(`        var ${matchvar} = new Dictionary<string, object?>();
`)
  } else {
    Content(`        var ${matchvar} = new Dictionary<string, object?>
        {
`)
    for (const [key, val] of matchEntries) {
      Content(`            ["${key}"] = setup.Idmap["${val}"],
`)
    }
    Content(`        };
`)
  }

  Content(`
        var ${listvar}Result = ${entvar}.List(${matchvar}, null);
        var ${listvar} = ${listvar}Result as List<object?>;
        Assert.True(${listvar} != null,
            $"expected list result to be a list, got {${listvar}Result?.GetType()}");
`)

  // Handle validators from step.valid
  const allSteps = Object.values(flow.step) as any[]
  if (step.valid) {
    for (const validator of step.valid) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.op &&
        ((s.input.ref ?? entity.name + '_ref01') === validRef))

      if ('ItemExists' === validator.apply && hasRefData) {
        const refDataVar = csVar(validRef + '_data')
        Content(`
        var ${listvar}Found = StructUtils.Select(
            TestRunner.EntityListToData(${listvar}!),
            new Dictionary<string, object?> { ["id"] = ${refDataVar}!["id"] });
        Assert.False(StructUtils.IsEmpty(${listvar}Found),
            "expected to find created entity in list");
`)
      } else if ('ItemNotExists' === validator.apply && hasRefData) {
        const refDataVar = csVar(validRef + '_data')
        Content(`
        var ${listvar}NotFound = StructUtils.Select(
            TestRunner.EntityListToData(${listvar}!),
            new Dictionary<string, object?> { ["id"] = ${refDataVar}!["id"] });
        Assert.True(StructUtils.IsEmpty(${listvar}NotFound),
            "expected removed entity to not be in list");
`)
      }
    }
  }
}


const generateUpdate: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = csVar(step.input.entvar ?? ref + '_ent')
  const datavar = csVar(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))
  const resdatavar = csVar(step.input.resdatavar ?? (ref + '_resdata' + (step.input.suffix ?? '')))
  const markdefvar = csVar(step.input.markdefvar ?? (ref + '_markdef' + (step.input.suffix ?? '')))
  const srcdatavar = csVar(step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const hasEntIdU = null != entity.id

  Content(`        // UPDATE
`)
  if (needsEnt) {
    Content(`        var ${entvar} = client.${entity.Name}();
`)
  }
  Content(`        var ${datavar}Up = new Dictionary<string, object?>
        {
`)
  if (hasEntIdU) {
    Content(`            ["id"] = ${srcdatavar}!["id"],
`)
  }

  // Add data entries from step.data
  if (step.data) {
    const dataEntries = Object.entries(step.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`            ["${key}"] = setup.Idmap["${key}"],
`)
    }
  }

  Content(`        };
`)

  // Handle TextFieldMark spec
  if (step.spec) {
    for (const spec of step.spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        const fieldname = step.input.textfield
        const fieldvalue = spec.def?.mark ?? `Mark01-${ref}`
        Content(`
        var ${markdefvar}Name = "${fieldname}";
        var ${markdefvar}Value = $"${fieldvalue}_{setup.Now}";
        ${datavar}Up[${markdefvar}Name] = ${markdefvar}Value;
`)
      }
    }
  }

  Content(`
        var ${resdatavar}Result = ${entvar}.Update(${datavar}Up, null);
        var ${resdatavar} = Helpers.ToMapAny(${resdatavar}Result is IEntity ue ? ue.Data() : ${resdatavar}Result);
        Assert.True(${resdatavar} != null, "expected update result to be a map");
`)
  if (hasEntIdU) {
    Content(`        Assert.True(StructRunner.DeepEqual(${resdatavar}!["id"], ${datavar}Up["id"]),
            "expected update result id to match");
`)
  }

  // Assert TextFieldMark
  if (step.spec) {
    for (const spec of step.spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        Content(`        Assert.True(Equals(${resdatavar}![${markdefvar}Name], ${markdefvar}Value),
            $"expected {${markdefvar}Name} to be updated, got {${resdatavar}[${markdefvar}Name]}");
`)
      }
    }
  }
}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = csVar(step.input.entvar ?? ref + '_ent')
  const matchvar = csVar(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const datavar = csVar(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))
  const srcdatavar = csVar(step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  // Check if srcdatavar was declared by a prior create step or preamble
  const flowHasCreate = Object.values(flow.step).some((s: any) => (s as any).op === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === csVar(preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.op) {
        const priorRef = s.input.ref ?? entity.name + '_ref01'
        const priorDatvar = csVar(s.input.datavar ?? (priorRef + '_data' + (s.input.suffix ?? '')))
        return priorDatvar === srcdatavar
      }
      return false
    })

  const hasEntId = null != entity.id

  Content(`        // LOAD
`)
  if (!hasEntVar) {
    Content(`        var ${entvar} = client.${entity.Name}();
`)
  }
  if (!hasSrcData && hasEntId) {
    Content(`        var ${srcdatavar}Raw = StructUtils.Items(
            Helpers.ToMapAny(StructUtils.GetPath(setup.Data, "existing.${entity.name}")));
        var ${srcdatavar} = ${srcdatavar}Raw.Count > 0
            ? Helpers.ToMapAny(${srcdatavar}Raw[0][1])
            : null;
`)
  }
  if (hasEntId) {
    Content(`        var ${matchvar} = new Dictionary<string, object?>
        {
            ["id"] = ${srcdatavar}!["id"],
        };
        var ${datavar}Loaded = ${entvar}.Load(${matchvar}, null);
        var ${datavar}LoadResult = Helpers.ToMapAny(${datavar}Loaded is IEntity le ? le.Data() : ${datavar}Loaded);
        Assert.True(${datavar}LoadResult != null, "expected load result to be a map");
        Assert.True(StructRunner.DeepEqual(${datavar}LoadResult!["id"], ${srcdatavar}["id"]),
            "expected load result id to match");
`)
  }
  else {
    Content(`        var ${matchvar} = new Dictionary<string, object?>();
        var ${datavar}Loaded = ${entvar}.Load(${matchvar}, null);
        Assert.True(${datavar}Loaded != null, "expected load result to be non-null");
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = csVar(step.input.entvar ?? ref + '_ent')
  const matchvar = csVar(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const srcdatavar = csVar(step.input.srcdatavar ?? (ref + '_data'))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`        // REMOVE
`)
  if (needsEnt) {
    Content(`        var ${entvar} = client.${entity.Name}();
`)
  }
  // Always match the prior-created entity by id to avoid mock-order flakes.
  Content(`        var ${matchvar} = new Dictionary<string, object?>
        {
            ["id"] = ${srcdatavar}!["id"],
        };
        ${entvar}.Remove(${matchvar}, null);
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
