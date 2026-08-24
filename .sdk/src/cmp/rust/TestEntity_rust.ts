
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


import { rustVarName, rustMethodName } from './utility_rust'


// Rust's GenCtx mirrors the shared shape (see TestEntity_ts.ts) plus the
// crate ident used to build qualified paths in emitted code.
type GenCtx = {
  model: Model
  entity: ModelEntity
  rustcrate: string
  flow: ModelEntityFlow
  PROJUPPER: string
}

type OpGen = (ctx: GenCtx, step: ModelEntityFlowStep, index: number) => void


const TestEntity = cmp(function TestEntity(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity
  const rustcrate: string = props.rustcrate

  const basicflow: ModelEntityFlow | undefined =
    getModelPath(model, `main.${KIT}.flow.Basic${nom(entity, 'Name')}Flow`)
  if (null == basicflow || true !== basicflow.active) {
    return
  }

  const PROJUPPER = envName(model)
  const ENTUPPER = envToken(entity.name)

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n        ("${PROJUPPER}_APIKEY", Value::str("NONE")),`
    : ''
  const apikeyLiveField = authActive
    ? `("apikey", getp(&env, "${PROJUPPER}_APIKEY"))`
    : ''

  const idnames = buildIdNames(entity, basicflow)
  const idnamesStr = idnames.map(n => `Value::str("${n}")`).join(', ')

  // All update data entries for alias generation.
  const allSteps = Object.values(basicflow.step) as any[]
  const updateStep = allSteps.find((s: any) => s.op === 'update')
  const updateData = updateStep?.data
    ? Object.entries(updateStep.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  const aliases = updateData.map(([k, v]: any) => [k, v])

  const genCtx: GenCtx = { model, entity, rustcrate, flow: basicflow, PROJUPPER }

  const opNames = Array.from(new Set(allSteps.map((s: any) => s.op).filter(Boolean)))
  const opsList = opNames.map(o => `"${o}"`).join(', ')

  // Same hazard as the csharp target: an entity whose basic flow has no ops
  // would emit `for op in []`, and rustc cannot infer the element type of an
  // empty array literal — E0282, type annotations needed. The loop is dead
  // code in that case, and so is the `mode` binding only it reads (which
  // would then warn as unused). Emit neither.
  const skipBlock = 0 === opNames.length ? '' : `    // Per-op sdk-test-control.json skip — the basic test exercises a flow
    // with multiple ops; skipping any op skips the whole flow.
    let mode = if setup.live { "live" } else { "unit" };
    for op in [${opsList}] {
        let (skip, reason) = is_control_skipped("entityOp", &format!("${entity.name}.{}", op), mode);
        if skip {
            let reason = if reason.is_empty() {
                "skipped via sdk-test-control.json".to_string()
            } else {
                reason
            };
            eprintln!("skip: {}", reason);
            return;
        }
    }
`

  const method = rustMethodName(entity.name)
  const evar = rustVarName(entity.name)

  File({ name: entity.name + '_entity_test.' + target.ext }, () => {

    Content(`// Generated basic-flow test for the ${entity.name} entity (model-driven;
// mirrors the go TestEntity generator).

#![allow(unused_variables, unused_mut, unused_imports)]

mod common;

use std::rc::Rc;

use common::*;

use ${rustcrate}::core::helpers::{getp, getpath, ja, jo, now_ms, setp, to_map};
use ${rustcrate}::utility::voxgigstruct as vs;
use ${rustcrate}::{test_sdk, Entity, ${model.const.Name}Entity, ${model.const.Name}SDK, Value};

#[test]
fn ${evar}_entity_instance() {
    let testsdk = test_sdk(Value::Noval, Value::Noval);
    let ent = testsdk.${method}(Value::Noval);
    assert_eq!(ent.get_name(), "${entity.name}");
}
`)

    // The stream test drives the list op; only emit it when the entity has a
    // list op (a create/load-only entity has no list endpoint, so
    // stream("list") panics with point_no_points).
    const flowHasList = allSteps.some((s: any) => 'list' === s.op)
    if (flowHasList) {
      Content(`
#[test]
fn ${evar}_entity_stream() {
    // stream() runs the list op through the full pipeline and yields each
    // result item. Seed two entities via test mode; with the \`streaming\`
    // feature active it yields the feature's incremental items, else it
    // falls back to the materialised items — either way every item yields.
    let seed = jo(vec![(
        "entity",
        jo(vec![(
            "${entity.name}",
            jo(vec![
                ("strm01", jo(vec![("id", Value::str("strm01"))])),
                ("strm02", jo(vec![("id", Value::str("strm02"))])),
            ]),
        )]),
    )]);

    let sdkopts = jo(vec![(
        "feature",
        jo(vec![("streaming", jo(vec![("active", Value::Bool(true))]))]),
    )]);

    let testsdk = test_sdk(seed.clone(), sdkopts);
    let ent = testsdk.${method}(Value::Noval);
    let items: Vec<Value> = ent
        .stream("list", Value::empty_map(), Value::empty_map())
        .expect("stream failed")
        .collect();
    assert_eq!(items.len(), 2, "stream should yield both seeded items");

    // Fallback: streaming inactive still yields both materialised items.
    let plainsdk = test_sdk(seed, Value::Noval);
    let plainent = plainsdk.${method}(Value::Noval);
    let plain_items: Vec<Value> = plainent
        .stream("list", Value::empty_map(), Value::empty_map())
        .expect("stream failed")
        .collect();
    assert_eq!(plain_items.len(), 2, "fallback stream should yield both items");
}
`)
    }

    Content(`
#[test]
fn ${evar}_entity_basic() {
    let setup = ${evar}_basic_setup(Value::Noval);
${skipBlock}    // The basic flow consumes synthetic IDs from the fixture. In live mode
    // without an *_ENTID env override, those IDs hit the live API and 4xx.
    if setup.synthetic_only {
        eprintln!("skip: live entity test uses synthetic IDs from fixture — set ${PROJUPPER}_TEST_${ENTUPPER}_ENTID JSON to run live");
        return;
    }
${allSteps.length > 0 ? '    let client = setup.client.clone();\n' : ''}`)

    // No create step: bootstrap entity data from existing fixture data.
    const flowHasCreate = allSteps.some((s: any) => s.op === 'create')
    if (!flowHasCreate) {
      const preambleVar = rustVarName(entity.name + '_ref01')
      Content(`
    // Bootstrap entity data from existing test data (no create step in flow).
    let ${preambleVar}_data_raw = vs::items(&to_map(&getpath(&["existing", "${entity.name}"], &setup.data)));
    let ${preambleVar}_data = to_map(&vs::get_elem(
        &vs::get_elem(&${preambleVar}_data_raw, &Value::Num(0.0), Value::Noval),
        &Value::Num(1.0),
        Value::Noval,
    ));
`)
    }

    // Model-driven step iteration.
    each(basicflow.step, (step: any, index: any) => {
      const opgen: OpGen = GENERATE_OP[step.op]
      if (opgen) {
        opgen(genCtx, step, index)
        Content('\n')
      }
    })

    Content(`}

`)

    // Setup function.
    Content(`fn ${evar}_basic_setup(extra: Value) -> EntityTestSetup {
    load_env_local();

    let mut entity_data_file = manifest_dir();
    entity_data_file.push("..");
    entity_data_file.push(".sdk");
    entity_data_file.push("test");
    entity_data_file.push("entity");
    entity_data_file.push("${entity.name}");
    entity_data_file.push("${entity.Name}TestData.json");

    let entity_data = read_json(&entity_data_file);

    let options = jo(vec![("entity", getp(&entity_data, "existing"))]);

    let client = test_sdk(options, extra.clone());

    // Generate idmap via transform, matching the TS pattern.
    let idmap = vs::transform(
        &ja(vec![${idnamesStr}]),
        &jo(vec![(
            "\`$PACK\`",
            ja(vec![
                Value::str(""),
                jo(vec![
                    ("\`$KEY\`", Value::str("\`$COPY\`")),
                    (
                        "\`$VAL\`",
                        ja(vec![
                            Value::str("\`$FORMAT\`"),
                            Value::str("upper"),
                            Value::str("\`$COPY\`"),
                        ]),
                    ),
                ]),
            ]),
        )]),
        None,
    )
    .unwrap_or_else(|_| Value::empty_map());

    // Detect ENTID env override before env_override consumes it. When live
    // mode is on without a real override, the basic test runs against
    // synthetic IDs from the fixture and 4xx's.
    let entid_env_raw = std::env::var("${PROJUPPER}_TEST_${ENTUPPER}_ENTID").unwrap_or_default();
    let idmap_overridden =
        !entid_env_raw.trim().is_empty() && entid_env_raw.trim().starts_with('{');

    let env = env_override(jo(vec![
        ("${PROJUPPER}_TEST_${ENTUPPER}_ENTID", idmap.clone()),
        ("${PROJUPPER}_TEST_LIVE", Value::str("FALSE")),
        ("${PROJUPPER}_TEST_EXPLAIN", Value::str("FALSE")),${apikeyEnvEntry}
    ]));

    let idmap_resolved = match to_map(&getp(&env, "${PROJUPPER}_TEST_${ENTUPPER}_ENTID")) {
        Value::Map(m) => Value::Map(m),
        _ => to_map(&idmap),
    };
`)

    // Aliases for ancestor field names.
    for (const [key, val] of aliases) {
      Content(`
    // Add ${key} alias for the update test.
    if getp(&idmap_resolved, "${key}").is_noval() {
        let aliased = getp(&idmap_resolved, "${val}");
        setp(&idmap_resolved, "${key}", aliased);
    }
`)
    }

    Content(`
    let live = getp(&env, "${PROJUPPER}_TEST_LIVE") == Value::str("TRUE");

    let client = if live {
        let merged = vs::merge(
            &ja(vec![jo(vec![${apikeyLiveField}]), extra]),
            None,
        );
        ${model.const.Name}SDK::new(to_map(&merged))
    } else {
        client
    };

    EntityTestSetup {
        client,
        data: entity_data,
        idmap: idmap_resolved,
        env: env.clone(),
        explain: getp(&env, "${PROJUPPER}_TEST_EXPLAIN") == Value::str("TRUE"),
        live,
        synthetic_only: live && !idmap_overridden,
        now: now_ms(),
    }
}
`)
  })
})


const generateCreate: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = rustVarName(step.input.entvar ?? ref + '_ent')
  const datavar = rustVarName(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`    // CREATE
`)
  if (needsEnt) {
    Content(`    let ${entvar} = client.${rustMethodName(entity.name)}(Value::Noval);
`)
  }

  Content(`    let ${datavar} = to_map(&getp(
        &getpath(&["new", "${entity.name}"], &setup.data),
        "${ref}",
    ));
`)

  // Match entries from the flow step.
  const matchEntries = getMatchEntries(step)
  for (const [key, val] of matchEntries) {
    Content(`    setp(&${datavar}, "${key}", getp(&setup.idmap, "${val}"));
`)
  }

  Content(`
    let ${datavar}_result = ${entvar}
        .create(${datavar}.clone(), Value::Noval)
        .expect("create failed");
    let ${datavar} = to_map(&${datavar}_result.data(None));
    assert!(
        matches!(${datavar}, Value::Map(_)),
        "expected create result to be a map"
    );
`)
  if (null != ctx.entity.id) {
    Content(`    assert!(
        !getp(&${datavar}, "id").is_noval(),
        "expected created entity to have an id"
    );
`)
  }
}


const generateList: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = rustVarName(step.input.entvar ?? ref + '_ent')
  const matchvar = rustVarName(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const listvar = rustVarName(step.input.listvar ?? (ref + '_list' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`    // LIST
`)
  if (needsEnt) {
    Content(`    let ${entvar} = client.${rustMethodName(entity.name)}(Value::Noval);
`)
  }

  // Match map.
  const matchEntries = getMatchEntries(step)
  if (matchEntries.length === 0) {
    Content(`    let ${matchvar} = Value::empty_map();
`)
  } else {
    Content(`    let ${matchvar} = Value::empty_map();
`)
    for (const [key, val] of matchEntries) {
      Content(`    setp(&${matchvar}, "${key}", getp(&setup.idmap, "${val}"));
`)
    }
  }

  Content(`
    let ${listvar} = ${entvar}
        .list(${matchvar}.clone(), Value::Noval)
        .expect("list failed");
    // list resolves to one ENTITY per record; the flow asserts on the
    // records, so map each through data().
    let ${listvar} = ja(${listvar}.iter().map(|e| e.data(None)).collect::<Vec<Value>>());
`)

  // Validators from step.valid.
  const allSteps = Object.values(flow.step) as any[]
  if (step.valid) {
    for (const validator of (step as any).valid) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.op &&
        ((s.input.ref ?? entity.name + '_ref01') === validRef))

      if ('ItemExists' === validator.apply && hasRefData) {
        const refDataVar = rustVarName(validRef + '_data')
        Content(`
    let found_item = vs::select(
        &entity_list_to_data(&${listvar}),
        &jo(vec![("id", getp(&${refDataVar}, "id"))]),
    );
    assert!(
        !vs::is_empty(&found_item),
        "expected to find created entity in list"
    );
`)
      } else if ('ItemNotExists' === validator.apply && hasRefData) {
        const refDataVar = rustVarName(validRef + '_data')
        Content(`
    let not_found_item = vs::select(
        &entity_list_to_data(&${listvar}),
        &jo(vec![("id", getp(&${refDataVar}, "id"))]),
    );
    assert!(
        vs::is_empty(&not_found_item),
        "expected removed entity to not be in list"
    );
`)
      }
    }
  }
}


const generateUpdate: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = rustVarName(step.input.entvar ?? ref + '_ent')
  const datavar = rustVarName(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))
  const resdatavar = rustVarName(step.input.resdatavar ?? (ref + '_resdata' + (step.input.suffix ?? '')))
  const markdefvar = rustVarName(step.input.markdefvar ?? (ref + '_markdef' + (step.input.suffix ?? '')))
  const srcdatavar = rustVarName(step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const hasEntIdU = null != entity.id

  Content(`    // UPDATE
`)
  if (needsEnt) {
    Content(`    let ${entvar} = client.${rustMethodName(entity.name)}(Value::Noval);
`)
  }
  Content(`    let ${datavar}_up = Value::empty_map();
`)
  if (hasEntIdU) {
    Content(`    setp(&${datavar}_up, "id", getp(&${srcdatavar}, "id"));
`)
  }

  // Data entries from step.data.
  if (step.data) {
    const dataEntries = Object.entries(step.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`    setp(&${datavar}_up, "${key}", getp(&setup.idmap, "${key}"));
`)
    }
  }

  // TextFieldMark spec.
  if (step.spec) {
    for (const spec of (step as any).spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        const fieldname = step.input.textfield
        const fieldvalue = spec.def?.mark ?? `Mark01-${ref}`
        Content(`
    let ${markdefvar}_name = "${fieldname}";
    let ${markdefvar}_value = format!("${fieldvalue}_{}", setup.now);
    setp(
        &${datavar}_up,
        ${markdefvar}_name,
        Value::str(${markdefvar}_value.clone()),
    );
`)
      }
    }
  }

  Content(`
    let ${resdatavar}_result = ${entvar}
        .update(${datavar}_up.clone(), Value::Noval)
        .expect("update failed");
    let ${resdatavar} = to_map(&${resdatavar}_result.data(None));
    assert!(
        matches!(${resdatavar}, Value::Map(_)),
        "expected update result to be a map"
    );
`)
  if (hasEntIdU) {
    Content(`    assert_eq!(
        getp(&${resdatavar}, "id"),
        getp(&${datavar}_up, "id"),
        "expected update result id to match"
    );
`)
  }

  // Assert TextFieldMark.
  if (step.spec) {
    for (const spec of (step as any).spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        Content(`    assert_eq!(
        getp(&${resdatavar}, ${markdefvar}_name),
        Value::str(${markdefvar}_value.clone()),
        "expected {} to be updated",
        ${markdefvar}_name
    );
`)
      }
    }
  }
}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = rustVarName(step.input.entvar ?? ref + '_ent')
  const matchvar = rustVarName(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const datavar = rustVarName(step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? '')))
  const srcdatavar = rustVarName(step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  // Was srcdatavar declared by a prior create step or the preamble?
  const flowHasCreate = Object.values(flow.step).some((s: any) => (s as any).op === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === rustVarName(preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.op) {
        const priorRef = s.input.ref ?? entity.name + '_ref01'
        const priorDatvar = rustVarName(s.input.datavar ?? (priorRef + '_data' + (s.input.suffix ?? '')))
        return priorDatvar === srcdatavar
      }
      return false
    })

  const hasEntId = null != entity.id

  Content(`    // LOAD
`)
  if (!hasEntVar) {
    Content(`    let ${entvar} = client.${rustMethodName(entity.name)}(Value::Noval);
`)
  }
  if (!hasSrcData && hasEntId) {
    Content(`    let ${srcdatavar}_raw = vs::items(&to_map(&getpath(&["existing", "${entity.name}"], &setup.data)));
    let ${srcdatavar} = to_map(&vs::get_elem(
        &vs::get_elem(&${srcdatavar}_raw, &Value::Num(0.0), Value::Noval),
        &Value::Num(1.0),
        Value::Noval,
    ));
`)
  }
  if (hasEntId) {
    Content(`    let ${matchvar} = jo(vec![("id", getp(&${srcdatavar}, "id"))]);
    let ${datavar}_loaded = ${entvar}
        .load(${matchvar}.clone(), Value::Noval)
        .expect("load failed");
    let ${datavar}_load_result = to_map(&${datavar}_loaded.data(None));
    assert!(
        matches!(${datavar}_load_result, Value::Map(_)),
        "expected load result to be a map"
    );
    assert_eq!(
        getp(&${datavar}_load_result, "id"),
        getp(&${srcdatavar}, "id"),
        "expected load result id to match"
    );
`)
  }
  else {
    Content(`    let ${matchvar} = Value::empty_map();
    let ${datavar}_loaded = ${entvar}
        .load(${matchvar}.clone(), Value::Noval)
        .expect("load failed");
    // load resolves to the ENTITY; the record is reached through data().
    assert!(
        !${datavar}_loaded.data(None).is_noval(),
        "expected load result to carry data"
    );
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = rustVarName(step.input.entvar ?? ref + '_ent')
  const matchvar = rustVarName(step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? '')))
  const srcdatavar = rustVarName(step.input.srcdatavar ?? (ref + '_data'))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`    // REMOVE
`)
  if (needsEnt) {
    Content(`    let ${entvar} = client.${rustMethodName(entity.name)}(Value::Noval);
`)
  }
  // Always match the prior-created entity by id to avoid mock-order flakes.
  Content(`    let ${matchvar} = jo(vec![("id", getp(&${srcdatavar}, "id"))]);
    ${entvar}
        .remove(${matchvar}.clone(), Value::Noval)
        .expect("remove failed");
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
