
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
  getMatchEntries, envName, envToken
} from '@voxgig/sdkgen'


import { cppVarName } from './utility_cpp'


type GenCtx = {
  model: Model
  entity: ModelEntity
  flow: ModelEntityFlow
}

type OpGen = (ctx: GenCtx, step: ModelEntityFlowStep, index: number) => void


// Generates <entity>_entity_test.cpp: the model-driven basic-flow test
// (unit mode against the in-memory mock transport). Mirrors the rust/go
// TestEntity generators.
const TestEntity = cmp(function TestEntity(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity

  const ProjectName = model.const.Name
  const PROJUPPER = envName(model)

  const basicflow: ModelEntityFlow | undefined =
    getModelPath(model, `main.${KIT}.flow.Basic${nom(entity, 'Name')}Flow`)
  if (null == basicflow || true !== basicflow.active) {
    return
  }

  const idnames = buildIdNames(entity, basicflow)
  const idnamesStr = idnames.map(n => `Value("${n}")`).join(', ')

  const allSteps = Object.values(basicflow.step) as any[]
  const updateStep = allSteps.find((s: any) => s.op === 'update')
  const updateData = updateStep?.data
    ? Object.entries(updateStep.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  const aliases = updateData.map(([k, v]: any) => [k, v])

  const genCtx: GenCtx = { model, entity, flow: basicflow }

  const opsList = Array.from(new Set(allSteps.map((s: any) => s.op).filter(Boolean)))
    .map(o => `"${o}"`).join(', ')

  const method = cppVarName(entity.name)
  const evar = cppVarName(entity.name)

  File({ name: entity.name + '_entity_test.cpp' }, () => {

    Content(`// Generated basic-flow test for the ${entity.name} entity (model-driven,
// unit mode; mirrors the rust/go TestEntity generator).

#include "runner_support.hpp"

using namespace sdk;
using namespace sdk::rs;

struct ${entity.Name}Setup {
  std::shared_ptr<${ProjectName}SDK> client;
  Value data;
  Value idmap;
  Value env;
  bool live = false;
  bool synthetic_only = false;
  long long now = 0;
};

static ${entity.Name}Setup ${evar}_basic_setup(const Value& extra) {
  load_env_local();

  std::string entity_data_file = "../.sdk/test/entity/${entity.name}/${entity.Name}TestData.json";
  Value entity_data = vs::parse_json(read_file(entity_data_file));

  Value options = vmap({{"entity", getp(entity_data, "existing")}});
  auto client = ${ProjectName}SDK::testSDK(options, extra);

  // idmap via transform (upper-cased id name synthetics), matching the donors.
  Value idmap = Struct::transform(
      vlist({${idnamesStr}}),
      vmap({{"\`$PACK\`", vlist({
        Value(""),
        vmap({
          {"\`$KEY\`", Value("\`$COPY\`")},
          {"\`$VAL\`", vlist({Value("\`$FORMAT\`"), Value("upper"), Value("\`$COPY\`")})}
        })
      })}}));
  if (!idmap.is_map()) idmap = vmap();

  Value env = env_override(vmap({
    {"${PROJUPPER}_TEST_${envToken(entity.name)}_ENTID", idmap},
    {"${PROJUPPER}_TEST_LIVE", Value("FALSE")},
    {"${PROJUPPER}_TEST_EXPLAIN", Value("FALSE")}
  }));

  Value idmap_resolved = Helpers::toMapAny(getp(env, "${PROJUPPER}_TEST_${envToken(entity.name)}_ENTID"));
  if (!idmap_resolved.is_map()) idmap_resolved = idmap;
`)

    for (const [key, val] of aliases) {
      Content(`
  if (getp(idmap_resolved, "${key}").is_undef()) {
    setp(idmap_resolved, "${key}", getp(idmap_resolved, "${val}"));
  }
`)
    }

    Content(`
  bool live = getp(env, "${PROJUPPER}_TEST_LIVE") == Value("TRUE");

  ${entity.Name}Setup s;
  s.client = client;
  s.data = entity_data;
  s.idmap = idmap_resolved;
  s.env = env;
  s.live = live;
  s.synthetic_only = false;
  s.now = now_ms();
  return s;
}

static void ${evar}_entity_instance() {
  auto testsdk = ${ProjectName}SDK::testSDK();
  auto ent = testsdk->${method}();
  ASSERT_EQ(ent->getName(), std::string("${entity.name}"), "entity name");
}

`)

    // The stream test drives the list op; only emit it when the entity has a
    // list op (a create/load-only entity has no list endpoint, so
    // stream("list") throws "Operation \"list\" has no endpoint definitions").
    const flowHasList = allSteps.some((s: any) => 'list' === s.op)
    if (flowHasList) {
      Content(`
static void ${evar}_entity_stream() {
  // stream() runs the list op through the full pipeline and returns the
  // result items. Seed two entities via test mode; with the streaming feature
  // active it yields the feature's incremental items, else it falls back to
  // the materialised items — either way every item is yielded.
  Value seed = vmap({{"entity", vmap({{"${entity.name}", vmap({
      {"strm01", vmap({{"id", Value("strm01")}})},
      {"strm02", vmap({{"id", Value("strm02")}})}})}})}});
  Value sdkopts = vmap({{"feature",
      vmap({{"streaming", vmap({{"active", Value(true)}})}})}});

  auto strsdk = ${ProjectName}SDK::testSDK(seed, sdkopts);
  auto se = strsdk->${method}();
  std::vector<Value> items = se->stream("list", Value::undef(), Value::undef());
  ASSERT_EQ((int)items.size(), 2, "stream yields both seeded items");

  auto plainsdk = ${ProjectName}SDK::testSDK(seed, Value::undef());
  auto pe = plainsdk->${method}();
  std::vector<Value> pitems = pe->stream("list", Value::undef(), Value::undef());
  ASSERT_EQ((int)pitems.size(), 2, "fallback stream yields both items");
}
`)
    }

    Content(`
static void ${evar}_entity_basic() {
  auto setup = ${evar}_basic_setup(Value::undef());
  std::string mode = setup.live ? "live" : "unit";
  for (const std::string& op : std::vector<std::string>{${opsList}}) {
    auto sk = is_control_skipped("entityOp", std::string("${entity.name}.") + op, mode);
    if (sk.first) { std::cerr << "skip: " << (sk.second.empty()? "sdk-test-control.json" : sk.second) << "\\n"; return; }
  }
  auto client = setup.client;
`)

    // No create step: bootstrap entity data from existing fixtures.
    const flowHasCreate = allSteps.some((s: any) => s.op === 'create')
    if (!flowHasCreate) {
      const preambleVar = cppVarName(entity.name + '_ref01')
      Content(`
  // Bootstrap entity data from existing test data (no create step in flow).
  // Declare _data at FUNCTION scope (later load/update steps reference it);
  // only _data_raw was declared, so the block-local assignment left _data
  // undeclared ("was not declared in this scope").
  Value ${preambleVar}_data_raw = Helpers::toMapAny(Struct::getpath(setup.data, {"existing", "${entity.name}"}));
  Value ${preambleVar}_data = vmap();
  {
    std::vector<Value> its = Struct::items(${preambleVar}_data_raw);
    ${preambleVar}_data = its.empty() ? vmap() : Helpers::toMapAny(pair_val(its[0]));
    if (!${preambleVar}_data.is_map()) ${preambleVar}_data = vmap();
  }
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

int main() {
  T_RUN(${evar}_entity_instance);
${flowHasList ? `  T_RUN(${evar}_entity_stream);\n` : ''}  T_RUN(${evar}_entity_basic);
  return sdktest::summary("${entity.name}_entity_test");
}
`)
  })
})


// declare a data var (C++ needs declaration); track declared vars per file is
// hard across generators, so each op declares with `Value` unless it's a known
// pre-declared ref. We use a simple convention: the first use declares it.
function decl(varname: string, declared: Set<string>): string {
  if (declared.has(varname)) return ''
  declared.add(varname)
  return 'Value '
}


const declaredVars = new Set<string>()


const generateCreate: OpGen = (ctx, step: any, index) => {
  const { entity } = ctx
  const ref = step.input?.ref ?? entity.name + '_ref01'
  const datavar = cppVarName(step.input?.datavar ?? (ref + '_data' + (step.input?.suffix ?? '')))
  const entvar = cppVarName(step.input?.entvar ?? ref + '_ent')

  Content(`  // CREATE
  auto ${entvar} = client->${cppVarName(entity.name)}();
  Value ${datavar} = Helpers::toMapAny(getp(Struct::getpath(setup.data, {"new", "${entity.name}"}), "${ref}"));
  if (!${datavar}.is_map()) ${datavar} = vmap();
`)
  declaredVars.add(datavar)

  const matchEntries = getMatchEntries(step)
  for (const [key, val] of matchEntries) {
    Content(`  setp(${datavar}, "${key}", getp(setup.idmap, "${val}"));
`)
  }

  Content(`  {
    Value ${datavar}_result = ${entvar}->create(Struct::clone(${datavar}), Value::undef())->data();
    ${datavar} = Helpers::toMapAny(${datavar}_result);
    if (!${datavar}.is_map()) ${datavar} = vmap();
    ASSERT_TRUE(${datavar}.is_map(), "expected create result to be a map");
`)
  if (null != ctx.entity.id) {
    Content(`    ASSERT_TRUE(!getp(${datavar}, "id").is_undef(), "expected created entity to have an id");
`)
  }
  Content(`  }
`)
}


const generateList: OpGen = (ctx, step: any, index) => {
  const { entity, flow } = ctx
  const ref = step.input?.ref ?? entity.name + '_ref01'
  const entvar = cppVarName(step.input?.entvar ?? ref + '_ent')
  const matchvar = cppVarName(step.input?.matchvar ?? (ref + '_match' + (step.input?.suffix ?? '')))
  const listvar = cppVarName(step.input?.listvar ?? (ref + '_list' + (step.input?.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`  // LIST
`)
  if (needsEnt) {
    Content(`  auto ${entvar} = client->${cppVarName(entity.name)}();
`)
  }
  Content(`  Value ${matchvar} = vmap();
`)
  const matchEntries = getMatchEntries(step)
  for (const [key, val] of matchEntries) {
    Content(`  setp(${matchvar}, "${key}", getp(setup.idmap, "${val}"));
`)
  }
  Content(`  auto ${listvar}_ents = ${entvar}->list(Struct::clone(${matchvar}), Value::undef());
  // list resolves to one ENTITY per record; the flow asserts on the records.
  Value ${listvar} = vlist();
  for (const auto& e : ${listvar}_ents) { ${listvar}.as_list()->push_back(e->data()); }
  ASSERT_TRUE(${listvar}.is_list(), "expected list result to be an array");
`)

  const allSteps = Object.values(flow.step) as any[]
  if (step.valid) {
    for (const validator of (step as any).valid) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.op &&
        ((s.input?.ref ?? entity.name + '_ref01') === validRef))
      if ('ItemExists' === validator.apply && hasRefData) {
        const refDataVar = cppVarName(validRef + '_data')
        Content(`  {
    std::vector<Value> found = Struct::select(entity_list_to_data(${listvar}), vmap({{"id", getp(${refDataVar}, "id")}}));
    ASSERT_TRUE(!found.empty(), "expected to find created entity in list");
  }
`)
      } else if ('ItemNotExists' === validator.apply && hasRefData) {
        const refDataVar = cppVarName(validRef + '_data')
        Content(`  {
    std::vector<Value> found = Struct::select(entity_list_to_data(${listvar}), vmap({{"id", getp(${refDataVar}, "id")}}));
    ASSERT_TRUE(found.empty(), "expected removed entity to not be in list");
  }
`)
      }
    }
  }
}


const generateUpdate: OpGen = (ctx, step: any, index) => {
  const { entity, flow } = ctx
  const ref = step.input?.ref ?? entity.name + '_ref01'
  const entvar = cppVarName(step.input?.entvar ?? ref + '_ent')
  const datavar = cppVarName(step.input?.datavar ?? (ref + '_data' + (step.input?.suffix ?? '')))
  const resdatavar = cppVarName(step.input?.resdatavar ?? (ref + '_resdata' + (step.input?.suffix ?? '')))
  const srcdatavar = cppVarName(step.input?.srcdatavar ?? (ref + '_data' + (step.input?.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))
  const hasEntIdU = null != entity.id

  Content(`  // UPDATE
`)
  if (needsEnt) {
    Content(`  auto ${entvar} = client->${cppVarName(entity.name)}();
`)
  }
  Content(`  Value ${datavar}_up = vmap();
`)
  if (hasEntIdU) {
    Content(`  setp(${datavar}_up, "id", getp(${srcdatavar}, "id"));
`)
  }
  if (step.data) {
    const dataEntries = Object.entries(step.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`  setp(${datavar}_up, "${key}", getp(setup.idmap, "${key}"));
`)
    }
  }
  let markname = ''
  let markval = ''
  if (step.spec) {
    for (const spec of (step as any).spec) {
      if ('TextFieldMark' === spec.apply && null != step.input?.textfield) {
        markname = step.input.textfield
        const fieldvalue = spec.def?.mark ?? `Mark01-${ref}`
        markval = `${fieldvalue}_`
        Content(`  std::string ${datavar}_markval = std::string("${fieldvalue}_") + std::to_string(setup.now);
  setp(${datavar}_up, "${markname}", Value(${datavar}_markval));
`)
      }
    }
  }
  Content(`  Value ${resdatavar}_result = ${entvar}->update(Struct::clone(${datavar}_up), Value::undef())->data();
  Value ${resdatavar} = Helpers::toMapAny(${resdatavar}_result);
  if (!${resdatavar}.is_map()) ${resdatavar} = vmap();
  ASSERT_TRUE(${resdatavar}.is_map(), "expected update result to be a map");
`)
  if (hasEntIdU) {
    Content(`  ASSERT_EQ_VAL(getp(${resdatavar}, "id"), getp(${datavar}_up, "id"), "expected update result id to match");
`)
  }
  if (markname) {
    Content(`  ASSERT_EQ_VAL(getp(${resdatavar}, "${markname}"), Value(${datavar}_markval), "expected ${markname} to be updated");
`)
  }
}


const generateLoad: OpGen = (ctx, step: any, index) => {
  const { entity, flow } = ctx
  const ref = step.input?.ref ?? entity.name + '_ref01'
  const entvar = cppVarName(step.input?.entvar ?? ref + '_ent')
  const matchvar = cppVarName(step.input?.matchvar ?? (ref + '_match' + (step.input?.suffix ?? '')))
  const datavar = cppVarName(step.input?.datavar ?? (ref + '_data' + (step.input?.suffix ?? '')))
  const srcdatavar = cppVarName(step.input?.srcdatavar ?? (ref + '_data' + (step.input?.suffix ?? '')))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))
  const hasEntId = null != entity.id

  Content(`  // LOAD
`)
  if (!hasEntVar) {
    Content(`  auto ${entvar} = client->${cppVarName(entity.name)}();
`)
  }
  if (hasEntId) {
    Content(`  Value ${matchvar} = vmap({{"id", getp(${srcdatavar}, "id")}});
  Value ${datavar}_loaded = ${entvar}->load(Struct::clone(${matchvar}), Value::undef())->data();
  Value ${datavar}_load_result = Helpers::toMapAny(${datavar}_loaded);
  ASSERT_TRUE(${datavar}_load_result.is_map(), "expected load result to be a map");
  ASSERT_EQ_VAL(getp(${datavar}_load_result, "id"), getp(${srcdatavar}, "id"), "expected load result id to match");
`)
  } else {
    Content(`  Value ${matchvar} = vmap();
  Value ${datavar}_loaded = ${entvar}->load(${matchvar}, Value::undef())->data();
  ASSERT_TRUE(!${datavar}_loaded.is_undef(), "expected load result to be non-nil");
`)
  }
}


const generateRemove: OpGen = (ctx, step: any, index) => {
  const { entity, flow } = ctx
  const ref = step.input?.ref ?? entity.name + '_ref01'
  const entvar = cppVarName(step.input?.entvar ?? ref + '_ent')
  const matchvar = cppVarName(step.input?.matchvar ?? (ref + '_match' + (step.input?.suffix ?? '')))
  const srcdatavar = cppVarName(step.input?.srcdatavar ?? (ref + '_data'))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`  // REMOVE
`)
  if (needsEnt) {
    Content(`  auto ${entvar} = client->${cppVarName(entity.name)}();
`)
  }
  Content(`  {
    Value ${matchvar} = vmap({{"id", getp(${srcdatavar}, "id")}});
    ${entvar}->remove(Struct::clone(${matchvar}), Value::undef());
  }
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
