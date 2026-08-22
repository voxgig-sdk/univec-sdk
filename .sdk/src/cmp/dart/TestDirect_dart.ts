
import {
  Model,
  ModelEntity,
  ModelPoint,
  nom,
  depluralize,
} from '@voxgig/apidef'


import {
  Content,
  File,
  Folder,
  Fragment,
  Slot,
  cmp,
  snakify,
  isAuthActive, envName, envToken
} from '@voxgig/sdkgen'


import {
  projectPath,
  dartValue,
} from './utility_dart'


const TestDirect = cmp(function TestDirect(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model
  const stdrep = ctx$.stdrep

  const entity: ModelEntity = props.entity

  const ff = projectPath('src/cmp/dart/fragment/')

  const PROJECTNAME = envName(model)
  const entidEnvVar = `${PROJECTNAME}_TEST_${envToken(entity.name)}_ENTID`

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n    '${PROJECTNAME}_APIKEY': 'NONE',`
    : ''
  const apikeyLiveField = authActive
    ? `
      'apikey': env['${PROJECTNAME}_APIKEY'],`
    : ''

  const opnames = Object.keys(entity.op || {})
  const hasLoad = opnames.includes('load')
  const hasList = opnames.includes('list')

  if (!hasLoad && !hasList) {
    return
  }

  Folder({ name: entity.name }, () => {

    File({ name: nom(entity, 'Name') + 'Direct_test.dart' }, () => {

      Fragment({
        from: ff + 'Direct.test.fragment.dart',
        replace: {
          SdkName: nom(model.const, 'Name'),
          EntityName: nom(entity, 'Name'),
          entityname: entity.name,
          PROJECTNAME,
          ...stdrep,
        }
      }, () => {


        Slot({ name: 'directSetup' }, () => {
          Content(`
Map<String, dynamic> directSetup([dynamic mockres]) {
  final calls = <Map<String, dynamic>>[];

  final env = envOverride({
    '${entidEnvVar}': <String, dynamic>{},
    '${PROJECTNAME}_TEST_LIVE': 'FALSE',${apikeyEnvEntry}
  });

  final live = 'TRUE' == env['${PROJECTNAME}_TEST_LIVE'];

  if (live) {
    final client = ${nom(model.const, 'Name')}SDK({${apikeyLiveField}
    });

    dynamic idmap = env['${entidEnvVar}'];
    if (idmap is String && idmap.startsWith('{')) {
      idmap = jsonDecode(idmap);
    }

    return {'client': client, 'calls': calls, 'live': live, 'idmap': idmap};
  }

  mockFetch(dynamic url, dynamic init) async {
    calls.add({'url': url, 'init': init});
    return {
      'status': 200,
      'statusText': 'OK',
      'headers': <String, dynamic>{},
      'json': () => mockres ?? {'id': 'direct01'},
    };
  }

  final client = ${nom(model.const, 'Name')}SDK({
    'base': 'http://localhost:8080',
    'system': {'fetch': mockFetch},
  });

  return {
    'client': client,
    'calls': calls,
    'live': live,
    'idmap': <String, dynamic>{},
  };
}

// direct() returns the raw response body. List endpoints often wrap the
// array in an envelope (e.g. { data: [...] }, { entities: [...] }). The
// test transforms the raw body to extract the first list — either the body
// itself or the first list property of an envelope map.
dynamic unwrapListData(dynamic data) {
  if (data is List) {
    return data;
  }
  if (data is Map) {
    for (final v in data.values) {
      if (v is List) {
        return v;
      }
    }
  }
  return null;
}
  `)
        })


        Slot({ name: 'direct' }, () => {

          if (hasLoad) {
            generateDirectLoad(model, entity)
          }

          if (hasList) {
            generateDirectList(model, entity)
          }
        })

      })
    })
  })
})


function generateDirectLoad(model: Model, entity: ModelEntity) {
  const loadOp = entity.op?.load
  const loadPoint: ModelPoint | undefined = loadOp?.points?.[0]

  if (null == loadPoint) {
    return
  }

  const allLoadParams = loadPoint.args?.params || []
  const loadPath = normalizePathParams(loadPoint.parts || [], allLoadParams, loadPoint.rename?.param)

  // Only path params that actually appear in the URL template drive the
  // direct-test path-param setup and URL-substitution asserts.
  const pathPlaceholders = new Set<string>()
  for (const part of (loadPoint.parts || [])) {
    if (typeof part === 'string' && part.startsWith('{') && part.endsWith('}')) {
      pathPlaceholders.add(part.slice(1, -1))
    }
  }
  const renameMap = (loadPoint.rename?.param || {}) as Record<string, string>
  const renamedPlaceholders = new Set<string>()
  for (const ph of pathPlaceholders) {
    renamedPlaceholders.add(ph)
    for (const [orig, renamed] of Object.entries(renameMap)) {
      if (renamed === ph) renamedPlaceholders.add(orig)
    }
  }
  const loadParams = allLoadParams.filter((p: any) =>
    renamedPlaceholders.has(p.name) || renamedPlaceholders.has(p.orig))

  // Required query params with spec-provided examples — needed to satisfy
  // the API contract in live mode; mock mode ignores them.
  const loadQuery = loadPoint.args?.query || []
  const liveQueryEntries = loadQuery
    .filter((q: any) => q.reqd && undefined !== q.example && null !== q.example)
  const hasLiveQuery = liveQueryEntries.length > 0
  const liveQueryLines = liveQueryEntries
    .map((q: any) => `        query['${q.name}'] = ${dartValue(q.example)};`)
    .join('\n')

  // Get list info for live mode bootstrapping
  const listOp = entity.op?.list
  const listPoint = listOp?.points?.[0]
  const listParams = listPoint?.args?.params || []
  const listPath = listPoint ? normalizePathParams(listPoint.parts || [], listParams, listPoint.rename?.param) : ''
  const hasList = null != listPoint

  // Ancestor params (not 'id') for live mode
  const ancestorParams = loadParams.filter((p: any) => p.name !== 'id')

  const paramAsserts = loadParams.map((p: any, i: number) =>
    `        ok(calls[0]['url'].toString().contains('direct0${i + 1}'));\n`).join('')

  // Build live list params
  const liveListParams = listParams.map((p: any) => {
    const key = p.name === 'id'
      ? entity.name + '01'
      : p.name.replace(/_id$/, '') + '01'
    return { name: p.name, key }
  })

  // Build live ancestor params for load
  const liveAncestorParams = ancestorParams.map((p: any) => {
    const key = p.name.replace(/_id$/, '') + '01'
    return { name: p.name, key }
  })

  const liveQueryPrefix = liveQueryLines ? liveQueryLines + '\n' : ''

  // Path params with spec-provided examples — when present, prefer them
  // over list-bootstrap.
  const liveExampleParams = loadParams.filter(
    (p: any) => undefined !== p.example && null !== p.example
  )
  const allLoadParamsHaveExamples =
    loadParams.length > 0 && liveExampleParams.length === loadParams.length

  // Set of idmap keys this test reads in live mode: used to skip-on-missing.
  let liveIdKeys: string[] = []

  const mockParamLines = loadParams.map((p: any, i: number) =>
    `        params['${p.name}'] = 'direct0${i + 1}';`).join('\n')

  let liveParamsBlock = ''
  if (allLoadParamsHaveExamples) {
    const exampleLines = loadParams.map(
      (p: any) => `        params['${p.name}'] = ${dartValue(p.example)};`
    ).join('\n')
    liveParamsBlock = `      if (true == setup['live']) {
${liveQueryPrefix}${exampleLines}
      } else {
${mockParamLines}
      }`
  }
  else if (hasList) {
    // List-bootstrap pattern picks the load id from a list call's response.
    liveIdKeys = liveAncestorParams.map((lp: any) => lp.key)
    const listParamLines = liveListParams.map((lp: any) =>
      `            '${lp.name}': setup['idmap']['${lp.key}'],`).join('\n')
    const ancestorParamLines = liveAncestorParams.map((lp: any) =>
      `        params['${lp.name}'] = setup['idmap']['${lp.key}'];`).join('\n')
    const idParamName = loadParams.find((p: any) => p.name === 'id')
      ? 'id'
      : (loadParams[0]?.name ?? 'id')

    liveParamsBlock = `      if (true == setup['live']) {
${liveQueryPrefix}        final listResult = await client.direct({
          'path': '${listPath}',
          'method': 'GET',
          'params': {
${listParamLines}
          },
        });
        if (true != listResult['ok']) {
          return; // skip: list call failed (likely synthetic IDs against live API)
        }
        final listArr = unwrapListData(listResult['data']);
        if (null == listArr || 0 == listArr.length) {
          return; // skip: no entities to load in live mode
        }
        final candidateId =
            (listArr[0] is Map ? listArr[0]['${idParamName}'] : null) ??
                (listArr[0] is Map ? listArr[0]['id'] : null);
        if (null == candidateId) {
          return; // skip: list response shape does not expose load identifier
        }
        params['${idParamName}'] = candidateId;
${ancestorParamLines}
      } else {
${mockParamLines}
      }`
  } else if (hasLiveQuery || loadParams.length > 0) {
    // Synthetic-only fallback: skip live when ENTID overrides are missing.
    if (loadParams.length > 0) {
      liveIdKeys = loadParams.map((p: any) => p.name + '01')
    }
    liveParamsBlock = `      if (true == setup['live']) {
${liveQueryPrefix.replace(/\n$/, '')}
      } else {
${mockParamLines}
      }`
  } else {
    liveParamsBlock = ''
  }

  const skipMissingLine = liveIdKeys.length > 0
    ? `      if (skipIfMissingIds(t, setup, ${JSON.stringify(liveIdKeys)})) {
        return;
      }\n`
    : ''

  Content(`
    test('direct-load-${entity.name}', (t) async {
      final setup = directSetup({'id': 'direct01'});
      if (maybeSkipControl(
          t, 'direct', 'direct-load-${entity.name}', true == setup['live'])) {
        return;
      }
${skipMissingLine}      final client = setup['client'];
      final calls = setup['calls'];

      final params = <String, dynamic>{};
      final query = <String, dynamic>{};
${liveParamsBlock}

      final result = await client.direct({
        'path': '${loadPath}',
        'method': 'GET',
        'params': params,
        'query': query,
      });

      if (true == setup['live']) {
        // Live mode is lenient: synthetic IDs frequently 4xx. Skip rather
        // than fail when the load endpoint isn't reachable.
        if (true != result['ok'] ||
            result['status'] < 200 ||
            result['status'] >= 300) {
          return;
        }
      } else {
        ok(true == result['ok']);
        ok(200 == result['status']);
        ok(null != result['data']);
        ok('direct01' == result['data']['id']);
        ok(1 == calls.length);
        ok('GET' == calls[0]['init']['method']);
${paramAsserts}      }
    });
`)
}


function generateDirectList(model: Model, entity: ModelEntity) {
  const listOp = entity.op?.list
  const listPoint: ModelPoint | undefined = listOp?.points?.[0]

  if (null == listPoint) {
    return
  }

  const listParams = listPoint.args?.params || []
  const listPath = normalizePathParams(listPoint.parts || [], listParams, listPoint.rename?.param)

  const listQuery = listPoint.args?.query || []
  const liveQueryLines = listQuery
    .filter((q: any) => q.reqd && undefined !== q.example && null !== q.example)
    .map((q: any) => `        query['${q.name}'] = ${dartValue(q.example)};`)
    .join('\n')

  const liveParams = listParams.map((p: any) => {
    const key = p.name === 'id'
      ? entity.name + '01'
      : p.name.replace(/_id$/, '') + '01'
    return { name: p.name, key }
  })

  const paramAsserts = listParams.map((p: any, i: number) =>
    `        ok(calls[0]['url'].toString().contains('direct0${i + 1}'));\n`).join('')

  let paramsBlock = ''
  if (listParams.length > 0 || liveQueryLines) {
    const liveLines = [
      liveQueryLines,
      liveParams.map((lp: any) =>
        `        params['${lp.name}'] = setup['idmap']['${lp.key}'];`).join('\n'),
    ].filter(Boolean).join('\n')
    const mockLines = listParams.map((p: any, i: number) =>
      `        params['${p.name}'] = 'direct0${i + 1}';`).join('\n')

    paramsBlock = `      if (true == setup['live']) {
${liveLines}
      }${mockLines ? ` else {
${mockLines}
      }` : ''}
`
  } else {
    paramsBlock = ''
  }

  const liveIdKeys: string[] = listParams.length > 0
    ? liveParams.map((lp: any) => lp.key)
    : []
  const skipMissingLine = liveIdKeys.length > 0
    ? `      if (skipIfMissingIds(t, setup, ${JSON.stringify(liveIdKeys)})) {
        return;
      }\n`
    : ''

  Content(`
    test('direct-list-${entity.name}', (t) async {
      final setup = directSetup([
        {'id': 'direct01'},
        {'id': 'direct02'}
      ]);
      if (maybeSkipControl(
          t, 'direct', 'direct-list-${entity.name}', true == setup['live'])) {
        return;
      }
${skipMissingLine}      final client = setup['client'];
      final calls = setup['calls'];

      final params = <String, dynamic>{};
      final query = <String, dynamic>{};
${paramsBlock}
      final result = await client.direct({
        'path': '${listPath}',
        'method': 'GET',
        'params': params,
        'query': query,
      });

      if (true == setup['live']) {
        // Live mode is lenient: synthetic IDs frequently 4xx and the list-
        // response shape varies wildly across public APIs. Skip rather than
        // fail when the call doesn't return a usable list.
        if (true != result['ok'] ||
            result['status'] < 200 ||
            result['status'] >= 300) {
          return;
        }
        final listArr = unwrapListData(result['data']);
        if (listArr is! List) {
          return;
        }
      } else {
        ok(true == result['ok']);
        ok(200 == result['status']);
        ok(null != result['data']);
        final listArr = unwrapListData(result['data']);
        ok(listArr is List);
        ok(2 == listArr.length);
        ok(1 == calls.length);
        ok('GET' == calls[0]['init']['method']);
${paramAsserts}      }
    });
`)
}


// Replace raw OpenAPI parameter names in path parts with model parameter
// names (see TestDirect_ts.ts for the full rationale).
function normalizePathParams(
  parts: string[],
  params: any[],
  rename?: Record<string, string>
): string {
  return parts.map((part: string) => {
    return part.replace(/\{([^}]+)\}/g, (match: string, rawName: string) => {
      const snaked = snakify(rawName)
      const depluralized = depluralize(snaked)
      const param = params.find((p: any) =>
          p.name === snaked || p.name === depluralized) ||
        params.find((p: any) =>
          p.orig === snaked || p.orig === depluralized)
      if (param) return '{' + param.name + '}'

      if (rename) {
        for (const [origCamel, renamedTo] of Object.entries(rename)) {
          if (renamedTo === rawName) {
            const origSnaked = snakify(origCamel)
            const origDepluralized = depluralize(origSnaked)
            const renamedParam = params.find(
              (p: any) => p.orig === origSnaked || p.name === origSnaked ||
                p.orig === origDepluralized || p.name === origDepluralized
            )
            if (renamedParam) return '{' + renamedParam.name + '}'
          }
        }
      }

      return match
    })
  }).join('/')
}


export {
  TestDirect
}
