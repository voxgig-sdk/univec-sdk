import { buildIdNames } from '@voxgig/sdkgen'
import { flowSteps } from '@voxgig/sdkgen'

import {
  flatten,
  items,
} from '@voxgig/struct'

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
  Folder,
  Fragment,
  Slot,
  cmp,
  each,
  isAuthActive, envName, envToken,
  serverVarEnv,
  serverVariables
} from '@voxgig/sdkgen'


import {
  projectPath, dartStringLiteral} from './utility_dart'


// GenCtx is the per-language generation context passed to every OpGen.
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
  const stdrep = ctx$.stdrep

  const entity: ModelEntity = props.entity

  const PROJENVNAME = envName(model)
  const ENTENVNAME = envToken(entity.name)
  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n    '${PROJENVNAME}_APIKEY': '',`
    : ''
  const apikeyLiveField = authActive
    ? `
        'apikey': env['${PROJENVNAME}_APIKEY'],`
    : ''

  // A templated server URL (OpenAPI server variables) makes a LIVE client
  // impossible to construct without values: makeOptions raises rather than
  // request a URL with a literal `{account_id}` in it. So the live suite
  // takes them from the environment the same way it takes the apikey.
  const svars = serverVariables(model)
  const serverEnvEntry = svars
    .map((v: any) => `\n    '${serverVarEnv(PROJENVNAME, v.name)}': ${dartStringLiteral(v.dflt)},`).join('')
  const serverLiveField = 0 === svars.length ? '' : `
        'server': <String, dynamic>{${svars
      .map((v: any) => `
          '${v.name}': env['${serverVarEnv(PROJENVNAME, v.name)}'],`).join('')}
        },`

  const ff = projectPath('src/cmp/dart/fragment/')

  Folder({ name: entity.name }, () => {

    File({ name: nom(entity, 'Name') + 'Entity_test.dart' }, () => {

      Fragment({
        from: ff + 'Entity.test.fragment.dart',
        replace: {
          SdkName: nom(model.const, 'Name'),
          EntityName: nom(entity, 'Name'),
          entityname: entity.name,
          PROJECTNAME: PROJENVNAME,
          ...stdrep,
        }
      }, () => {

        const basicflow = getModelPath(model, `main.${KIT}.flow.Basic${nom(entity, 'Name')}Flow`)

        const dobasic = basicflow && true === basicflow.active

        if (!dobasic) {
          return;
        }

        const idlist = buildIdNames(entity, basicflow)

        // The stream test drives the `list` op; only emit it when the entity
        // actually has a list op (a create-only entity like a *_result has no
        // list endpoint, so ent.stream('list', …) would throw point_no_points).
        const flowHasList = Object.values(flowSteps(basicflow))
          .some((s: any) => 'list' === s.o)
        Slot({ name: 'stream' }, () => {
          if (!flowHasList) {
            return
          }
          Content(`test('stream', (t) async {
      // stream() runs the list op through the full pipeline and yields each
      // result item. Seed two entities via test mode; with the \`streaming\`
      // feature active it yields the feature's incremental items, else it
      // falls back to the materialised items — either way every item yields.
      final seed = <String, dynamic>{
        'entity': {
          '${entity.name}': {
            'strm01': <String, dynamic>{'id': 'strm01'},
            'strm02': <String, dynamic>{'id': 'strm02'},
          }
        }
      };

      final sdkopts = <String, dynamic>{};
      if (null != config.feature['streaming']) {
        sdkopts['feature'] = {
          'streaming': {'active': true}
        };
      }

      final testsdk = ${model.Name}SDK.test(seed, sdkopts);
      final ent = testsdk.${nom(entity, 'Name')}();

      final seen = [];
      await for (final item in ent.stream('list', <String, dynamic>{})) {
        seen.add(item);
      }
      equal(2, seen.length);

      // Fallback: with streaming inactive, stream() still yields both items
      // from the materialised result.
      final plainsdk = ${model.Name}SDK.test(seed);
      final plainent = plainsdk.${nom(entity, 'Name')}();
      final seen2 = [];
      await for (final item in plainent.stream('list', <String, dynamic>{})) {
        seen2.add(item);
      }
      equal(2, seen2.length);
    });
`)
        })

        Slot({ name: 'basicSetup' }, () => {
          Content(`
Map<String, dynamic> basicSetup([dynamic extra]) {
  final options = <String, dynamic>{};

  final entityDataFile = resolveTestPath(
      '../.sdk/test/entity/${entity.name}/${nom(entity, 'Name')}TestData.json');

  final entityDataSource = File(entityDataFile).readAsStringSync();

  final entityData = jsonDecode(entityDataSource);

  options['entity'] = entityData['existing'];

  var client = ${model.Name}SDK.test(options, extra);
  final struct = client.utility().struct;
  final merge = struct.merge;
  final transform = struct.transform;

  dynamic idmap = transform(
      <dynamic>['${idlist.join("', '")}'],
      <String, dynamic>{
        '\`\\\$PACK\`': <dynamic>[
          '',
          <String, dynamic>{
            '\`\\\$KEY\`': '\`\\\$COPY\`',
            '\`\\\$VAL\`': <dynamic>['\`\\\$FORMAT\`', 'upper', '\`\\\$COPY\`'],
          }
        ]
      });

  // Detect whether the user provided a real ENTID JSON via env var. The
  // basic flow consumes synthetic IDs from the fixture file; without an
  // override those synthetic IDs reach the live API and 4xx. Surface this
  // to the test so it can skip rather than fail.
  final idmapEnvVal =
      Platform.environment['${PROJENVNAME}_TEST_${ENTENVNAME}_ENTID'];
  final idmapOverridden =
      null != idmapEnvVal && idmapEnvVal.trim().startsWith('{');

  final env = envOverride({
    '${PROJENVNAME}_TEST_${ENTENVNAME}_ENTID': idmap,
    '${PROJENVNAME}_TEST_LIVE': 'FALSE',
    '${PROJENVNAME}_TEST_EXPLAIN': 'FALSE',${apikeyEnvEntry}${serverEnvEntry}
  });

  idmap = env['${PROJENVNAME}_TEST_${ENTENVNAME}_ENTID'];

  final live = 'TRUE' == env['${PROJENVNAME}_TEST_LIVE'];

  if (live) {
    client = ${model.Name}SDK(merge([
      // FIRST, so the generated fields below win: sdk-test-control.json's
      // test.client.options adds to the live client, it does not redirect it.
      liveClientOptions(),
      <String, dynamic>{${apikeyLiveField}${serverLiveField}
      },
      // 'extra ?? {}', not a bare 'extra': merge returns null when the last
      // entry is null, and basicSetup is normally called with no argument at
      // all - so a bare 'extra' silently discarded the apikey and server
      // values above and handed the SDK null.
      extra ?? <String, dynamic>{}
    ]));
  }

  final setup = <String, dynamic>{
    'idmap': idmap,
    'env': env,
    'options': options,
    'client': client,
    'struct': struct,
    'data': entityData,
    'explain': 'TRUE' == env['${PROJENVNAME}_TEST_EXPLAIN'],
    'live': live,
    'syntheticOnly': live && !idmapOverridden,
    'now': DateTime.now().millisecondsSinceEpoch,
  };

  return setup;
}
`)
        })


        Slot({ name: 'basic' }, () => {
          const flowHasCreate = Object.values(flowSteps(basicflow)).some(
            (s: any) => s.o === 'create'
          )

          // The basic test exercises a flow with one or more ops (load,
          // list, create, update, remove, ...). The control file lets users
          // skip per-op for an entity. Since the flow is sequential and
          // dependent (e.g. update needs prior load), skipping ANY op the
          // flow exercises skips the whole basic test.
          const flowOps = Array.from(new Set(
            (flowSteps(basicflow) as any[]).map((s: any) => s.o).filter(Boolean)
          ))
          const flowOpsLiteral = '[' + flowOps.map((o: any) => `'${o}'`).join(', ') + ']'

          Content(`
      final live = 'TRUE' == Platform.environment['${PROJENVNAME}_TEST_LIVE'];
      for (final op in ${flowOpsLiteral}) {
        if (maybeSkipControl(t, 'entityOp', '${entity.name}.' + op, live)) {
          return;
        }
      }

      final setup = basicSetup();
      // The basic flow consumes synthetic IDs and field values from the
      // fixture (entity TestData.json). Those don't exist on the live API.
      // Skip live runs unless the user provided a real ENTID env override.
      if (true == setup['syntheticOnly']) {
        t.skip('live entity test uses synthetic IDs from fixture — set ${PROJENVNAME}_TEST_${ENTENVNAME}_ENTID JSON to run live');
        return;
      }
      final client = setup['client'];
      final struct = setup['struct'];

      final isempty = struct.isempty;
      final select = struct.select;

`)

          // When the flow has no create step, bootstrap the entity data variable
          // from existing test data so that subsequent update/load/remove steps
          // can reference it.
          if (!flowHasCreate) {
            const ref01 = entity.name + '_ref01'
            Content(`      final ${ref01}_data =
          (setup['data']['existing']['${entity.name}'] as Map).values.first;
`)
          }

          const genCtx: GenCtx = {
            model, entity, flow: basicflow, PROJUPPER: PROJENVNAME,
          }
          each(flowSteps(basicflow), (step: ModelEntityFlowStep, index: number) => {
            const opgen = GENERATE_OP[step.o]
            if (null != opgen) {
              opgen(genCtx, step, index)
              Content('\n')
            }
          })
        })
      })
    })
  })
})


const generateCreate: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const datavar = step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? ''))

  const priorSteps = flowSteps(flow).slice(0, Number(index))
  const needsEnt = !priorSteps.some(s =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  const hasDatvar = priorSteps.some(s => {
    if ('create' === s.o) {
      const priorRef = s.i.ref ?? entity.name + '_ref01'
      const priorDatvar = s.i.datavar ?? (priorRef + '_data' + (s.i.suffix ?? ''))
      return priorDatvar === datavar
    }
    return false
  })

  Content(`
      // CREATE
`)
  if (needsEnt) {
    Content(`      final ${entvar} = client.${nom(entity, 'Name')}();
`)
  }
  if (hasDatvar) {
    Content(`      ${datavar} = setup['data']['new']['${entity.name}']['${ref}'];
`)
  } else {
    Content(`      dynamic ${datavar} = setup['data']['new']['${entity.name}']['${ref}'];
`)
  }

  each(step.m, (mi: any) => {
    Content(`      ${datavar}['${mi.key$}'] = setup['idmap']['${mi.val$}'];
`)
  })

  const hasEntIdC = null != entity.id

  Content(`
      ${datavar} = (await ${entvar}.create(${datavar})).data();
`)
  if (hasEntIdC) {
    Content(`      ok(null != ${datavar}['id']);
`)
  }
  else {
    Content(`      ok(null != ${datavar});
`)
  }
}


const generateList: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const matchvar = step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? ''))
  const listvar = step.i.listvar ?? (ref + '_list' + (step.i.suffix ?? ''))

  const priorSteps = flowSteps(flow).slice(0, Number(index))
  const needsEnt = !priorSteps.some(s =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  Content(`
      // LIST
`)
  if (needsEnt) {
    Content(`      final ${entvar} = client.${nom(entity, 'Name')}();
`)
  }
  Content(`      final ${matchvar} = <String, dynamic>{};
`)

  each(step.m, (mi: any) => {
    Content(`      ${matchvar}['${mi.key$}'] = setup['idmap']['${mi.val$}'];
`)
  })

  Content(`
      final ${listvar} = (await ${entvar}.list(${matchvar})).map((e) => e.data()).toList();
`)
  const allSteps = flowSteps(flow)
  for (let vI = 0; vI < step.v.length; vI++) {
    const validator = step.v[vI]
    const validRef = validator.def?.ref
    const hasRefData = validRef && allSteps.some(s => 'create' === s.o &&
      ((s.i.ref ?? entity.name + '_ref01') === validRef))

    // listvar is ALREADY a list of data maps — the list call above maps
    // .data() over the entity instances. Mapping .data() a second time here
    // called it on a plain Map and every entity test died at runtime with
    // "Class '_Map<String, dynamic>' has no instance method 'data'".
    if ('ItemExists' === validator.apply && hasRefData) {
      Content(`
      ok(!isempty(select(
          ${listvar},
          {'id': ${validRef}_data['id']})));
`)
    }
    else if ('ItemNotExists' === validator.apply && hasRefData) {
      Content(`
      ok(isempty(select(
          ${listvar},
          {'id': ${validRef}_data['id']})));
`)
    }
  }
}


const generateUpdate: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const datavar = step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? ''))
  const resdatavar = step.i.resdatavar ?? (ref + '_resdata' + (step.i.suffix ?? ''))
  const markdefvar = step.i.markdefvar ?? (ref + '_markdef' + (step.i.suffix ?? ''))
  const srcdatavar = step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? ''))

  const priorSteps = flowSteps(flow).slice(0, Number(index))
  const needsEnt = !priorSteps.some(s =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  const hasEntIdU = null != entity.id

  // When the update writes into the same variable a prior step declared,
  // reuse it; otherwise declare fresh.
  const declared = datavar === srcdatavar

  const updvar = declared ? datavar + '_upd' : datavar

  Content(`
      // UPDATE
`)
  if (needsEnt) {
    Content(`      final ${entvar} = client.${nom(entity, 'Name')}();
`)
  }
  Content(`      final ${updvar} = <String, dynamic>{};
`)
  if (hasEntIdU) {
    Content(`      ${updvar}['id'] = ${srcdatavar}['id'];
`)
  }

  each(step.d, (mi: any) => {
    if ('id' !== mi.key$) {
      Content(`      ${updvar}['${mi.key$}'] = setup['idmap']['${mi.key$}'];
`)
    }
  })


  for (let sI = 0; sI < step.s.length; sI++) {
    const spec = step.s[sI]
    if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
      const fieldname = step.i.textfield
      const fieldvalue = spec.def.mark
      Content(`
      final ${markdefvar} = <String, dynamic>{
        'name': '${fieldname}',
        'value': '${fieldvalue}_' + setup['now'].toString(),
      };
      ${updvar}[${markdefvar}['name']] = ${markdefvar}['value'];
`)
    }
  }

  Content(`
      final ${resdatavar} = (await ${entvar}.update(${updvar})).data();
`)
  if (hasEntIdU) {
    Content(`      ok(${resdatavar}['id'] == ${updvar}['id']);
`)
  }
  else {
    Content(`      ok(null != ${resdatavar});
`)
  }

  for (let sI = 0; sI < step.s.length; sI++) {
    const spec = step.s[sI]
    if ('TextFieldMark' === spec.apply && null != step.i.textfield) {
      Content(`
      ok(${resdatavar}[${markdefvar}['name']] == ${markdefvar}['value']);
`)
    }
  }

}


const generateLoad: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const matchvar = step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? ''))
  const datavarRaw = step.i.datavar ?? (ref + '_data' + (step.i.suffix ?? ''))
  const srcdatavar = step.i.srcdatavar ?? (ref + '_data' + (step.i.suffix ?? ''))

  const priorSteps = flowSteps(flow).slice(0, Number(index))
  const hasEntVar = priorSteps.some(s =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  // Check if srcdatavar was declared by a prior create step or by the
  // preamble bootstrap (which runs when the flow has no create step)
  const flowHasCreate = flowSteps(flow).some(s => s.o === 'create')
  const preambleRef = entity.name + '_ref01'
  const hasSrcData = (!flowHasCreate && srcdatavar === preambleRef + '_data') ||
    priorSteps.some(s => {
      if ('create' === s.o) {
        const priorRef = s.i.ref ?? entity.name + '_ref01'
        const priorDatvar = s.i.datavar ?? (priorRef + '_data' + (s.i.suffix ?? ''))
        return priorDatvar === srcdatavar
      }
      return false
    })

  // Loading into the same name the source data already uses needs a
  // distinct local (Dart cannot shadow within the same block).
  const datavar = datavarRaw === srcdatavar ? datavarRaw + '_loaded' : datavarRaw

  const hasEntId = null != entity.id

  // When the entity has no id model field but the load operation requires
  // path parameters, calling load({}) leaves the URL with literal {param}
  // placeholders. There is no synthetic identifier to substitute, so skip
  // emitting the load step's call in that case — but still declare the
  // entity-var if no prior step has, so later flow steps compile.
  const loadOp = entity.op?.load
  const loadPoint = loadOp?.points?.[0]
  const loadPathParams = loadPoint?.g?.params || []
  const loadHasRequiredParams = loadPathParams.some((p: any) => p.r !== false)
  if (!hasEntId && loadHasRequiredParams) {
    if (!hasEntVar) {
      Content(`
      // LOAD: skipped — no entity id field and load requires path params.
      // Entity-var is declared here so later flow steps still compile.
      final ${entvar} = client.${nom(entity, 'Name')}();
`)
    }
    return
  }

  Content(`
      // LOAD
`)
  if (!hasEntVar) {
    Content(`      final ${entvar} = client.${nom(entity, 'Name')}();
`)
  }
  if (!hasSrcData && hasEntId) {
    Content(`      final ${srcdatavar} =
          (setup['data']['existing']['${entity.name}'] as Map).values.first;
`)
  }
  if (hasEntId) {
    Content(`      final ${matchvar} = <String, dynamic>{};
      ${matchvar}['id'] = ${srcdatavar}['id'];
      final ${datavar} = (await ${entvar}.load(${matchvar})).data();
      ok(${datavar}['id'] == ${srcdatavar}['id']);
`)
  }
  else {
    Content(`      final ${matchvar} = <String, dynamic>{};
      final ${datavar} = (await ${entvar}.load(${matchvar})).data();
      ok(null != ${datavar});
`)
  }
}


const generateRemove: OpGen = (ctx, step, index) => {
  const { entity, flow } = ctx
  const ref = step.i.ref ?? entity.name + '_ref01'
  const entvar = step.i.entvar ?? ref + '_ent'
  const matchvar = step.i.matchvar ?? (ref + '_match' + (step.i.suffix ?? ''))
  const srcdatavar = step.i.srcdatavar ?? (ref + '_data')

  const priorSteps = flowSteps(flow).slice(0, Number(index))
  const needsEnt = !priorSteps.some(s =>
    ['create', 'list', 'load', 'update', 'remove'].includes(s.o))

  Content(`
      // REMOVE
`)
  if (needsEnt) {
    Content(`      final ${entvar} = client.${nom(entity, 'Name')}();
`)
  }
  // Always match the prior-created entity by id. The mock test feature
  // removes the first match in entmap, so without a specific id the
  // result depends on hash-sort order and flakes.
  Content(`      final ${matchvar} = <String, dynamic>{'id': ${srcdatavar}['id']};
      await ${entvar}.remove(${matchvar});
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
