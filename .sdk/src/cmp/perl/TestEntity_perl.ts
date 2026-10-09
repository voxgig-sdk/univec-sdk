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
  isAuthActive, envName, envToken,
  serverVarEnv,
  serverVariables,
  liveFlowNeeds, liveStrict, liveStrictNote,
} from '@voxgig/sdkgen'

import { perlStringLiteral } from './utility_perl'


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


// The live prologue of a flow built from offline fixtures: blocked without
// the ids it binds, a create-less load reading the first listed record, and
// a lenient run reporting a failed check without failing the test.
function liveFlowGate(N: string, entity: any, needs: any, entidEnv: string,
  strict: boolean): string {
  const label = entity.name + ': basic flow'
  let out = ''
  if (0 < needs.keys.length) {
    out += `  if ($setup->{live}) {
    my @missing = grep { $setup->{synthetic_only} || !defined $setup->{idmap}{$_} } (${needs.keys.map((k: string) => `'${k}'`).join(', ')});
    if (@missing) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live entity test blocked: needs ' . join(', ', @missing) . ' via ${entidEnv}');
      last BASIC_FLOW;
    }
  }
`
  }
  if (null != needs.blocked) {
    out += `  if ($setup->{live}) {
    ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live entity test blocked: ${needs.blocked}');
    last BASIC_FLOW;
  }
`
  }
  out += '  my $client = $setup->{client};\n'
  if (null != needs.discover) {
    const match = Object.entries(needs.discover)
      .map(([k, v]: any) => `'${k}' => $setup->{idmap}{'${v}'}`).join(', ')
    out += `  if ($setup->{live}) {
    ${N}TestRunner::live_existing($setup, LIVE_STRICT, '${label}', '${entity.name}',
      sub { $client->${entity.Name}(undef)->list({${match}}, undef) }) or last BASIC_FLOW;
  }
`
  }
  if (!strict) {
    out += `  local $main::TODO = $setup->{live} ? 'live run, main.kit.test.live.strict is false' : undef;
  eval {
`
  }
  return out
}


const TestEntity = cmp(function TestEntity(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const entity: ModelEntity = props.entity
  const target = props.target

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
    ? `\n    '${PROJUPPER}_APIKEY' => '',`
    : ''
  const apikeyLiveField = authActive
    ? `\n        'apikey' => $env->{'${PROJUPPER}_APIKEY'},`
    : ''

  // A templated server URL (OpenAPI server variables) makes a LIVE client
  // impossible to construct without values: makeOptions raises rather than
  // request a URL with a literal `{account_id}` in it. So the live suite
  // takes them from the environment the same way it takes the apikey.
  const svars = serverVariables(model)
  const serverEnvEntry = svars
    .map((v: any) => `\n    '${serverVarEnv(PROJUPPER, v.name)}' => ${perlStringLiteral(v.dflt)},`).join('')
  const serverLiveField = 0 === svars.length ? '' : `
        'server' => {${svars
      .map((v: any) => `
          '${v.name}' => $env->{'${serverVarEnv(PROJUPPER, v.name)}'},`).join('')}
        },`

  const idnames = buildIdNames(entity, basicflow)
  const idnamesStr = idnames.map(n => `'${n}'`).join(', ')

  const allSteps = Object.values(flowSteps(basicflow)) as any[]
  const updateStep = allSteps.find((s: any) => s.o === 'update')
  const updateData = updateStep?.d
    ? Object.entries(updateStep.d).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    : []
  const aliases = updateData.map(([k, v]: any) => [k, v])

  // An entity whose basic flow has no steps yields an EMPTY list, and Perl's
  // `for my $x () {` is a syntax error (unlike `for my $x (()) {`, which is a
  // valid empty loop) — the whole test file then fails to compile. The loop
  // below therefore wraps this in a second pair of parens, which is a no-op
  // for a non-empty list because Perl flattens it.
  const opsList = Array.from(new Set(
    (allSteps as any[]).map((s: any) => s.o).filter(Boolean)))
    .map(o => `'${o}'`).join(', ')

  const genCtx: GenCtx = { model, entity, flow: basicflow, N, PROJUPPER }

  const strict = liveStrict(model, target.name)
  const needs = liveFlowNeeds(entity, basicflow)
  // The failure tests stream and list with no match, so they need a list a
  // bare call can reach.
  const hasList = opReachable((entity.op as any)?.list, [])

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

${liveStrictNote(strict, '#')}
use constant LIVE_STRICT => ${strict ? 1 : 0};

{
  my $testsdk = ${N}SDK->test(undef, undef);
  my $ent = $testsdk->${entity.Name}(undef);
  ok(defined $ent, '${entity.name}: create instance');
}
${hasList ? failureTests(N, entity) : ''}${validateTest(N, entity)}
BASIC_FLOW: {
  my $setup = ${entity.name}_basic_setup(undef);
  my $_live = $setup->{live} ? 1 : 0;
  # Per-op sdk-test-control.json skip.
  for my $_op ((${opsList})) {
    my ($_should_skip, $_reason) = ${N}TestRunner::is_control_skipped(
      'entityOp', "${entity.name}." . $_op, $_live ? 'live' : 'unit');
    if ($_should_skip) {
      note($_reason || 'skipped via sdk-test-control.json');
      pass('${entity.name}: basic flow skipped via sdk-test-control.json');
      last BASIC_FLOW;
    }
  }
${liveFlowGate(N, entity, needs, ENTIDVAR, strict)}  my %V;

`)

    // Check if the flow has a create step
    const flowHasCreate = allSteps.some((s: any) => s.o === 'create')
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
    each(flowSteps(basicflow), (step: any, index: any) => {
      const opgen: OpGen = GENERATE_OP[step.o]
      if (opgen) {
        opgen(genCtx, step, index)
        Content('\n')
      }
    })

    Content(`${strict ? '' : `    1;
  } or ${N}TestRunner::live_observe($@, $setup, LIVE_STRICT, '${entity.name}: basic flow');
`}}

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

  # Whether *_ENTID supplied the idmap, read before env_override consumes
  # it: without it, the ids a live flow binds are the fixture's synthetic ones.
  my $entid_env_raw = $ENV{'${ENTIDVAR}'};
  my $idmap_overridden = (defined $entid_env_raw && $entid_env_raw =~ /^\\s*\\{/) ? 1 : 0;

  my $env = ${N}TestRunner::env_override({
    '${ENTIDVAR}' => $idmap,
    '${PROJUPPER}_TEST_LIVE' => 'FALSE',
    '${PROJUPPER}_TEST_EXPLAIN' => 'FALSE',${apikeyEnvEntry}${serverEnvEntry}
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
      # FIRST, so the generated fields below win: sdk-test-control.json's
      # test.client.options adds to the live client, it does not redirect it.
      ${N}TestRunner::live_client_options(),
      {${apikeyLiveField}${serverLiveField}
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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const datavar = step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? ''))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const matchvar = step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? ''))
  const listvar = step.i.listvar ?? (ref + '_list' + (step.i.suffix ?? ''))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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
  const allSteps = Object.values(flowSteps(flow)) as any[]
  if (step.v) {
    for (const validator of step.v) {
      const validRef = validator.def?.ref
      const hasRefData = validRef && allSteps.some((s: any) => 'create' === s.o &&
        ((s.i.ref ?? entity.name + '_ref01') === validRef))

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
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const datavar = step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? ''))
  const resdatavar = step.i.resdatavar ?? (ref + '_resdata' + (step.i.suffix ?? ''))
  const markdefvar = step.i.markdefvar ?? (ref + '_markdef' + (step.i.suffix ?? ''))
  const srcdatavar = step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? ''))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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

  if (step.d) {
    const dataEntries = Object.entries(step.d).filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    for (const [key] of dataEntries) {
      Content(`    '${key}' => $setup->{idmap}{'${key}'},
`)
    }
  }

  Content(`  };
`)

  if (step.s) {
    for (const spec of step.s) {
      if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
        const fieldname = step.i.textfield
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

  if (step.s) {
    for (const spec of step.s) {
      if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
        Content(`  is($V{${resdatavar}}{ $V{${markdefvar}_name} }, $V{${markdefvar}_value}, '${entity.name} update: mark');
`)
      }
    }
  }
}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow, N } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const matchvar = step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? ''))
  const datavar = step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? ''))
  const srcdatavar = step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? ''))

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const hasEntVar = priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  const flowHasCreate = Object.values(flowSteps(flow)).some((s: any) => (s as any).o === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === (preambleRef + '_data')) ||
    priorSteps.some((s: any) => {
      if ('create' === s.o) {
        const priorRef = s.i.ref ?? entity.name + '_ref01'
        const priorDatvar = s.i.datavar ?? (priorRef + '_data' + (s.i.suffix ?? ''))
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
${parentMatch(step, matchvar)}  $V{${datavar}_loaded} = $V{${entvar}}->load($V{${matchvar}}, undef);
  $V{${datavar}_load_result} = ${N}Helpers::to_map(ref($V{${datavar}_loaded}) && $V{${datavar}_loaded}->can('data_get') ? $V{${datavar}_loaded}->data_get : $V{${datavar}_loaded});
  ok(defined $V{${datavar}_load_result}, '${entity.name} load: data');
  is($V{${datavar}_load_result}{id}, $V{${srcdatavar}}{id}, '${entity.name} load: id');
`)
  }
  else {
    Content(`  $V{${matchvar}} = {};
${parentMatch(step, matchvar)}  $V{${datavar}_loaded} = $V{${entvar}}->load($V{${matchvar}}, undef);
  ok(defined $V{${datavar}_loaded}, '${entity.name} load: data');
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow, N } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const matchvar = step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? ''))
  const srcdatavar = step.i.srcdatavar ?? (ref + '_data')

  const priorSteps = Object.values(flowSteps(flow)).slice(0, Number(index)) as any[]
  const needsEnt = !priorSteps.some((s: any) =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

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
${parentMatch(step, matchvar)}  $V{${entvar}}->remove($V{${matchvar}}, undef);
  pass('${entity.name} remove: completed');
`)
}


// A child's route names its parents, and an entity no earlier step has
// filled knows none of them, so the call itself gives each parent id. A live
// ENTID may key a parent by its field name, the fixture by its own name.
function parentMatch(step: any, matchvar: string): string {
  return Object.entries(step.m || {})
    .filter(([k]: any) => k !== 'id' && !k.endsWith('$'))
    .map(([key, val]: any) => `  $V{${matchvar}}{'${key}'} = $setup->{idmap}{'${key}'} // $setup->{idmap}{'${val}'};
`).join('')
}


const GENERATE_OP: Record<string, OpGen> = {
  create: generateCreate,
  list: generateList,
  update: generateUpdate,
  load: generateLoad,
  remove: generateRemove,
}


// A failed operation raises from a stream as it does from the operation: a
// transport failure, and a hook that rejects the call. A dying hook fires
// PreUnexpected, and under throw false the call returns undef. The caller's
// ctrl stays its own.
function failureTests(N: string, entity: ModelEntity): string {
  const Entity = entity.Name
  const Hook = N + 'EntityTest' + Entity + 'FailHook'
  return `
{
  package ${Hook};
  our @ISA = ('${N}BaseFeature');

  sub new {
    my ($class) = @_;
    my $self = ${N}BaseFeature::new($class);
    $self->{name} = 'failhook';
    $self->{unexpected} = 0;
    return $self;
  }

  sub init { }
  sub PreSpec { die "${entity.name} hook failed\\n" }
  sub PreUnexpected { $_[0]->{unexpected}++; return }
}

{
  my $offline = { net => { offline => 1 } };
  my $died = !eval {
    my $next = ${N}SDK->test($offline, undef)->${Entity}(undef)->stream('list', undef, undef);
    1 while defined $next->();
    1;
  };
  like($died ? "$@" : '', qr/offline/, '${entity.name}: a failed stream raises');

  ok(eval {
    my $next = ${N}SDK->test($offline, undef)->${Entity}(undef)
      ->stream('list', undef, { ctrl => { throw => 0 } });
    1 while defined $next->();
    1;
  }, '${entity.name}: under throw false a failed stream ends');

  if (${N}Config::shared_config()->{feature}{rbac}) {
    my $denied = ${N}SDK->test(undef, { feature => { rbac => { active => 1, deny => 1 } } });
    my $denyerr = eval {
      my $next = $denied->${Entity}(undef)->stream('list', undef, undef);
      1 while defined $next->();
      undef;
    } // $@;
    is(ref $denyerr ? $denyerr->{code} : undef, 'rbac_denied',
      '${entity.name}: a denied stream raises');
  }
}

{
  my $explain = {};
  my $ctrl = { explain => $explain };
  my $next = ${N}SDK->test(undef, undef)->${Entity}(undef)
    ->stream('list', undef, { ctrl => $ctrl });
  1 while defined $next->();
  is_deeply([sort keys %$ctrl], ['explain'], '${entity.name}: the stream leaves the caller ctrl');
  ok($explain == $ctrl->{explain} && 0 < keys %$explain,
    '${entity.name}: the caller explain record is filled');
}

{
  my $hook = ${Hook}->new;
  my $client = ${N}SDK->new({ feature => { test => { active => 1 } }, extend => [$hook] });

  my $err = eval { $client->${Entity}(undef)->list(undef, undef); undef } // $@;
  like("$err", qr/hook failed/, '${entity.name}: a dying hook fails the operation');
  ok(0 < $hook->{unexpected}, '${entity.name}: PreUnexpected fired');

  my $fired = $hook->{unexpected};
  my $out = eval { $client->${Entity}(undef)->list(undef, { throw => 0 }) };
  ok(!$@ && !defined $out, '${entity.name}: under throw false the call returns undef');
  ok($fired < $hook->{unexpected}, '${entity.name}: PreUnexpected fired under throw false');
}

{
  my $seed = { entity => { '${entity.name}' => { l1 => { id => 'l1' }, l2 => { id => 'l2' } } } };
  my $items = ${N}SDK->test($seed, undef)->${Entity}(undef)->list(undef, undef);
  # list resolves to one entity per record; data_get reads the record.
  is(scalar(@$items), 2, '${entity.name}: list answers each seeded record');
  my $entities = grep {
    Scalar::Util::blessed($_) && $_->can('data_get') && Voxgig::Struct::ismap($_->data_get)
  } @$items;
  is($entities, 2, '${entity.name}: each listed item is an entity carrying its record');
}
`
}


// An invalid request fails with validate's own error, before it is sent.
function validateTest(N: string, entity: ModelEntity): string {
  const bad = invalidRequest(entity)
  if (null == bad) {
    return ''
  }
  const args = Object.entries(bad.args)
    .map(([k, v]) => perlStringLiteral(k) + ' => ' +
      ('string' === typeof v ? perlStringLiteral(v) : true === v ? '1' : String(v)))
    .join(', ')
  return `
SKIP: {
  skip('feature not present in this SDK: validate', 1)
    unless ${N}Config::shared_config()->{feature}{validate};
  my $client = ${N}SDK->test(undef, { feature => { validate => { active => 1 } } });
  my $err = eval { $client->${entity.Name}(undef)->${bad.op}({ ${args} }, undef); undef } // $@;
  is(ref $err ? $err->{code} : undef, 'validate_failed',
    '${entity.name}: an invalid request fails with validate_failed');
}
`
}


export {
  TestEntity
}
