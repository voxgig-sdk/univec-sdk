
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


// See TestEntity_ts.ts for the GenCtx/OpGen contract. Flow-step variables
// are held in a single declared perl hash (%V) so generated steps never
// fight over `my` declarations.
type GenCtx = {
  model: Model
  entity: ModelEntity
  flow: ModelEntityFlow
  N: string
  PROJUPPER: string
}

type OpGen = (ctx: GenCtx, step: ModelEntityFlowStep, index: number) => void


const TestEntity = cmp(function TestEntity(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const entity: ModelEntity = props.entity

  const basicflow: ModelEntityFlow | undefined =
    getModelPath(model, `main.${KIT}.flow.Basic${nom(entity, 'Name')}Flow`)
  if (null == basicflow || true !== basicflow.active) {
    return
  }

  const N = model.const.Name
  const PROJUPPER = envName(model)
  const ENTUPPER = envToken(entity.name)
  const ENTIDVAR = `${PROJUPPER}_TEST_${ENTUPPER}_ENTID`

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n    '${PROJUPPER}_APIKEY' => 'NONE',`
    : ''
  const apikeyLiveField = authActive
    ? `\n        'apikey' => $env->{'${PROJUPPER}_APIKEY'},`
    : ''

  const idnames = buildIdNames(entity, basicflow)
  const idnamesStr = idnames.map(n => `'${n}'`).join(', ')

  const allSteps = Object.values(basicflow.step) as any[]
  const updateStep = allSteps.find((s: any) => s.op === 'update')
  const updateData = updateStep?.data
    ? Object.entries(updateStep.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  const aliases = updateData.map(([k, v]: any) => [k, v])

  const opsList = Array.from(new Set(
    (allSteps as any[]).map((s: any) => s.op).filter(Boolean)))
    .map(o => `'${o}'`).join(', ')

  const genCtx: GenCtx = { model, entity, flow: basicflow, N, PROJUPPER }

  File({ name: entity.name + '_entity.t' }, () => {

    Content(`#!perl
# ${entity.Name} entity test

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd ();

use ${N}SDK;
require(Cwd::abs_path("$FindBin::Bin/runner.pm"));

{
  my $testsdk = ${N}SDK->test(undef, undef);
  my $ent = $testsdk->${entity.Name}(undef);
  ok(defined $ent, '${entity.name}: create instance');
}

BASIC_FLOW: {
  my $setup = ${entity.name}_basic_setup(undef);
  my $_live = $setup->{live} ? 1 : 0;
  # Per-op sdk-test-control.json skip.
  for my $_op (${opsList}) {
    my ($_should_skip, $_reason) = ${N}TestRunner::is_control_skipped(
      'entityOp', "${entity.name}." . $_op, $_live ? 'live' : 'unit');
    if ($_should_skip) {
      note($_reason || 'skipped via sdk-test-control.json');
      pass('${entity.name}: basic flow skipped via sdk-test-control.json');
      last BASIC_FLOW;
    }
  }
  # The basic flow consumes synthetic IDs from the fixture. In live mode
  # without an *_ENTID env override, those IDs hit the live API and 4xx.
  if ($setup->{synthetic_only}) {
    note('live entity test uses synthetic IDs from fixture - set ${ENTIDVAR} JSON to run live');
    pass('${entity.name}: basic flow skipped (synthetic IDs only)');
    last BASIC_FLOW;
  }
  my $client = $setup->{client};
  my %V;

`)

    // Check if the flow has a create step
    const flowHasCreate = allSteps.some((s: any) => s.op === 'create')
    if (!flowHasCreate) {
      Content(`  # Bootstrap entity data from existing test data.
  $V{${entity.name}_ref01_data_raw} = Voxgig::Struct::items(${N}Helpers::to_map(
    ${N}Helpers::gpath($setup->{data}, 'existing.${entity.name}')));
  $V{${entity.name}_ref01_data} = undef;
  if (@{ $V{${entity.name}_ref01_data_raw} || [] }) {
    $V{${entity.name}_ref01_data} = ${N}Helpers::to_map($V{${entity.name}_ref01_data_raw}[0][1]);
  }

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

    Content(`}

`)

    // Generate setup function
    Content(`sub ${entity.name}_basic_setup {
  my ($extra) = @_;
  ${N}TestRunner::load_env_local();

  my $entity_data_file = Cwd::abs_path(
    "$FindBin::Bin/../../.sdk/test/entity/${entity.name}/${entity.Name}TestData.json");
  my $entity_data = do {
    open my $fh, '<:raw', $entity_data_file or die "Cannot open $entity_data_file: $!";
    local $/;
    Voxgig::Struct::parse_json(<$fh>);
  };

  my $options = {};
  $options->{entity} = $entity_data->{existing};

  my $client = ${N}SDK->test($options, $extra);

  # Generate idmap via transform.
  my $idmap = Voxgig::Struct::transform(
    [${idnamesStr}],
    {
      '\`$PACK\`' => ['', {
        '\`$KEY\`' => '\`$COPY\`',
        '\`$VAL\`' => ['\`$FORMAT\`', 'upper', '\`$COPY\`'],
      }],
    }
  );

  # Detect ENTID env override before env_override consumes it. When live
  # mode is on without a real override, the basic test runs against
  # synthetic IDs from the fixture and 4xx's. Surface this so the test can
  # skip.
  my $entid_env_raw = $ENV{'${ENTIDVAR}'};
  my $idmap_overridden = (defined $entid_env_raw && $entid_env_raw =~ /^\\s*\\{/) ? 1 : 0;

  my $env = ${N}TestRunner::env_override({
    '${ENTIDVAR}' => $idmap,
    '${PROJUPPER}_TEST_LIVE' => 'FALSE',
    '${PROJUPPER}_TEST_EXPLAIN' => 'FALSE',${apikeyEnvEntry}
  });

  my $idmap_resolved = ${N}Helpers::to_map($env->{'${ENTIDVAR}'});
  if (!defined $idmap_resolved) {
    $idmap_resolved = ${N}Helpers::to_map($idmap);
  }
`)

    // Add aliases
    for (const [key, val] of aliases) {
      Content(`  if (!defined $idmap_resolved->{'${key}'}) {
    $idmap_resolved->{'${key}'} = $idmap_resolved->{'${val}'};
  }
`)
    }

    Content(`
  if ((($env->{'${PROJUPPER}_TEST_LIVE'}) || '') eq 'TRUE') {
    my $merged_opts = Voxgig::Struct::merge([
      {${apikeyLiveField}
      },
      (Voxgig::Struct::ismap($extra) ? $extra : {}),
    ]);
    $client = ${N}SDK->new(${N}Helpers::to_map($merged_opts));
  }

  my $live = ((($env->{'${PROJUPPER}_TEST_LIVE'}) || '') eq 'TRUE') ? 1 : 0;
  return {
    'client' => $client,
    'data' => $entity_data,
    'idmap' => $idmap_resolved,
    'env' => $env,
    'explain' => ((($env->{'${PROJUPPER}_TEST_EXPLAIN'}) || '') eq 'TRUE') ? 1 : 0,
    'live' => $live,
    'synthetic_only' => ($live && !$idmap_overridden) ? 1 : 0,
    'now' => ${N}Helpers::now_ms(),
  };
}

done_testing();
`)
  })
})


const generateCreate: OpGen = (ctx, step, index) => {
  const { entity, flow, N } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = step.input.entvar ?? ref + '_ent'
  const datavar = step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? ''))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`  # CREATE
`)
  if (needsEnt) {
    Content(`  $V{${entvar}} = $client->${entity.Name}(undef);
`)
  }

  Content(`  $V{${datavar}} = ${N}Helpers::to_map(${N}Helpers::gp(
    ${N}Helpers::gpath($setup->{data}, 'new.${entity.name}'), '${ref}'));
`)

  const matchEntries = getMatchEntries(step)
  for (const [key, val] of matchEntries) {
    Content(`  $V{${datavar}}{'${key}'} = $setup->{idmap}{'${val}'};
`)
  }

  Content(`
  $V{${datavar}_result} = $V{${entvar}}->create($V{${datavar}}, undef);
  $V{${datavar}} = ${N}Helpers::to_map(ref($V{${datavar}_result}) && $V{${datavar}_result}->can('data_get') ? $V{${datavar}_result}->data_get : $V{${datavar}_result});
  ok(defined $V{${datavar}}, '${entity.name} create: data');
`)
  if (null != ctx.entity.id) {
    Content(`  ok(defined $V{${datavar}}{id}, '${entity.name} create: id');
`)
  }
}

const generateList: OpGen = (ctx, step, index) => {
  const { entity, flow, N } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = step.input.entvar ?? ref + '_ent'
  const matchvar = step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? ''))
  const listvar = step.input.listvar ?? (ref + '_list' + (step.input.suffix ?? ''))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`  # LIST
`)
  if (needsEnt) {
    Content(`  $V{${entvar}} = $client->${entity.Name}(undef);
`)
  }

  const matchEntries = getMatchEntries(step)
  if (matchEntries.length === 0) {
    Content(`  $V{${matchvar}} = {};
`)
  } else {
    Content(`  $V{${matchvar}} = {
`)
    for (const [key, val] of matchEntries) {
      Content(`    '${key}' => $setup->{idmap}{'${val}'},
`)
    }
    Content(`  };
`)
  }

  Content(`
  $V{${listvar}_result} = $V{${entvar}}->list($V{${matchvar}}, undef);
  ok(Voxgig::Struct::islist($V{${listvar}_result}), '${entity.name} list: is array');
`)

  // Handle validators
  const allSteps = Object.values(flow.step) as any[]
  if (step.valid) {
    for (const validator of step.valid) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.op &&
        ((s.input.ref ?? entity.name + '_ref01') === validRef))

      if ('ItemExists' === validator.apply && hasRefData) {
        const refDataVar = validRef + '_data'
        Content(`
  $V{found_item} = Voxgig::Struct::select(
    ${N}TestRunner::entity_list_to_data($V{${listvar}_result}),
    { 'id' => $V{${refDataVar}}{id} });
  ok(!Voxgig::Struct::isempty($V{found_item}), '${entity.name} list: item exists');
`)
      } else if ('ItemNotExists' === validator.apply && hasRefData) {
        const refDataVar = validRef + '_data'
        Content(`
  $V{not_found_item} = Voxgig::Struct::select(
    ${N}TestRunner::entity_list_to_data($V{${listvar}_result}),
    { 'id' => $V{${refDataVar}}{id} });
  ok(Voxgig::Struct::isempty($V{not_found_item}), '${entity.name} list: item not exists');
`)
      }
    }
  }
}


const generateUpdate: OpGen = (ctx, step, index) => {
  const { entity, flow, N } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = step.input.entvar ?? ref + '_ent'
  const datavar = step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? ''))
  const resdatavar = step.input.resdatavar ?? (ref + '_resdata' + (step.input.suffix ?? ''))
  const markdefvar = step.input.markdefvar ?? (ref + '_markdef' + (step.input.suffix ?? ''))
  const srcdatavar = step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? ''))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const hasEntIdU = null != entity.id

  Content(`  # UPDATE
`)
  if (needsEnt) {
    Content(`  $V{${entvar}} = $client->${entity.Name}(undef);
`)
  }
  Content(`  $V{${datavar}_up} = {
`)
  if (hasEntIdU) {
    Content(`    'id' => $V{${srcdatavar}}{id},
`)
  }

  if (step.data) {
    const dataEntries = Object.entries(step.data).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`    '${key}' => $setup->{idmap}{'${key}'},
`)
    }
  }

  Content(`  };
`)

  if (step.spec) {
    for (const spec of step.spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        const fieldname = step.input.textfield
        const fieldvalue = spec.def?.mark ?? `Mark01-${ref}`
        Content(`
  $V{${markdefvar}_name} = '${fieldname}';
  $V{${markdefvar}_value} = '${fieldvalue}_' . $setup->{now};
  $V{${datavar}_up}{ $V{${markdefvar}_name} } = $V{${markdefvar}_value};
`)
      }
    }
  }

  Content(`
  $V{${resdatavar}_result} = $V{${entvar}}->update($V{${datavar}_up}, undef);
  $V{${resdatavar}} = ${N}Helpers::to_map(ref($V{${resdatavar}_result}) && $V{${resdatavar}_result}->can('data_get') ? $V{${resdatavar}_result}->data_get : $V{${resdatavar}_result});
  ok(defined $V{${resdatavar}}, '${entity.name} update: data');
`)
  if (hasEntIdU) {
    Content(`  is($V{${resdatavar}}{id}, $V{${datavar}_up}{id}, '${entity.name} update: id');
`)
  }

  if (step.spec) {
    for (const spec of step.spec) {
      if ('TextFieldMark' === spec.apply && null != step.input.textfield) {
        Content(`  is($V{${resdatavar}}{ $V{${markdefvar}_name} }, $V{${markdefvar}_value}, '${entity.name} update: mark');
`)
      }
    }
  }
}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow, N } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = step.input.entvar ?? ref + '_ent'
  const matchvar = step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? ''))
  const datavar = step.input.datavar ?? (ref + '_data' + (step.input.suffix ?? ''))
  const srcdatavar = step.input.srcdatavar ?? (ref + '_data' + (step.input.suffix ?? ''))

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  const flowHasCreate = Object.values(flow.step).some((s: any) => (s as any).op === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === (preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.op) {
        const priorRef = s.input.ref ?? entity.name + '_ref01'
        const priorDatvar = s.input.datavar ?? (priorRef + '_data' + (s.input.suffix ?? ''))
        return priorDatvar === srcdatavar
      }
      return false
    })

  const hasEntId = null != entity.id

  Content(`  # LOAD
`)
  if (!hasEntVar) {
    Content(`  $V{${entvar}} = $client->${entity.Name}(undef);
`)
  }
  if (!hasSrcData && hasEntId) {
    Content(`  $V{${srcdatavar}_raw} = Voxgig::Struct::items(${N}Helpers::to_map(
    ${N}Helpers::gpath($setup->{data}, 'existing.${entity.name}')));
  $V{${srcdatavar}} = undef;
  if (@{ $V{${srcdatavar}_raw} || [] }) {
    $V{${srcdatavar}} = ${N}Helpers::to_map($V{${srcdatavar}_raw}[0][1]);
  }
`)
  }
  if (hasEntId) {
    Content(`  $V{${matchvar}} = {
    'id' => $V{${srcdatavar}}{id},
  };
  $V{${datavar}_loaded} = $V{${entvar}}->load($V{${matchvar}}, undef);
  $V{${datavar}_load_result} = ${N}Helpers::to_map(ref($V{${datavar}_loaded}) && $V{${datavar}_loaded}->can('data_get') ? $V{${datavar}_loaded}->data_get : $V{${datavar}_loaded});
  ok(defined $V{${datavar}_load_result}, '${entity.name} load: data');
  is($V{${datavar}_load_result}{id}, $V{${srcdatavar}}{id}, '${entity.name} load: id');
`)
  }
  else {
    Content(`  $V{${matchvar}} = {};
  $V{${datavar}_loaded} = $V{${entvar}}->load($V{${matchvar}}, undef);
  ok(defined $V{${datavar}_loaded}, '${entity.name} load: data');
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow, N } = ctx
  const ref = step.input.ref ?? entity.name + '_ref01'
  const entvar = step.input.entvar ?? ref + '_ent'
  const matchvar = step.input.matchvar ?? (ref + '_match' + (step.input.suffix ?? ''))
  const srcdatavar = step.input.srcdatavar ?? (ref + '_data')

  const priorSteps = Object.values(flow.step).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.op))

  Content(`  # REMOVE
`)
  if (needsEnt) {
    Content(`  $V{${entvar}} = $client->${entity.Name}(undef);
`)
  }
  // Always match the prior-created entity by id to avoid mock-order flakes.
  Content(`  $V{${matchvar}} = {
    'id' => $V{${srcdatavar}}{id},
  };
  $V{${entvar}}->remove($V{${matchvar}}, undef);
  pass('${entity.name} remove: completed');
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
