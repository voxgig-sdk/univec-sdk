
import {
  Model,
  ModelEntity,
  nom,
  depluralize,
} from '@voxgig/apidef'

import {
  Content,
  File,
  cmp,
  snakify,
  isAuthActive, envName, envToken,
  serverVarEnv,
  serverVariables,
  pointParts,
  liveStrict,
  liveStrictNote,
} from '@voxgig/sdkgen'

import { perlStringLiteral } from './utility_perl'


// Blocked without the ids its request needs, rather than sent with undef.
function liveKeysBlock(N: string, label: string, block: string, keys: string[],
  entidEnvVar: string): string {
  return 0 === keys.length ? '' : `  if ($setup->{live}) {
    my @missing = grep { !defined $setup->{idmap}{$_} } (${keys.map((k) => `'${k}'`).join(', ')});
    if (@missing) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live test blocked: needs ' . join(', ', @missing) . ' via ${entidEnvVar}');
      last ${block};
    }
  }
`
}


function normalizePathParams(
  parts: string[],
  params: any[],
  rename?: Record<string, string>
): string {
  return parts.map((part: string) => {
    return part.replace(/\{([^}]+)\}/g, (match: string, rawName: string) => {
      const snaked = snakify(rawName)
      const depluralized = depluralize(snaked)
      // Prefer exact name match - orig matches can collide when one param's
      // original name was renamed to another param's current name (e.g. badge
      // load: param 'group_id' has orig 'id', and another param has name 'id').
      const param = params.find((p: any) =>
          p.n === snaked || p.n === depluralized) ||
        params.find((p: any) =>
          p.or === snaked || p.or === depluralized)
      if (param) return '{' + param.n + '}'

      if (rename) {
        for (const [origCamel, renamedTo] of Object.entries(rename)) {
          if (renamedTo === rawName) {
            const origSnaked = snakify(origCamel)
            const origDepluralized = depluralize(origSnaked)
            const renamedParam = params.find(
              (p: any) => p.or === origSnaked || p.n === origSnaked ||
                p.or === origDepluralized || p.n === origDepluralized
            )
            if (renamedParam) return '{' + renamedParam.n + '}'
          }
        }
      }

      return match
    })
  }).join('/')
}


// Single-quoted Perl string literal for a scalar example value.
function perlScalar(v: any): string {
  if ('number' === typeof v || 'boolean' === typeof v) {
    return 'boolean' === typeof v ? (v ? '1' : '0') : String(v)
  }
  const s = String(v).replace(/\\/g, '\\\\').replace(/'/g, "\\'")
  return `'${s}'`
}


const TestDirect = cmp(function TestDirect(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const entity: ModelEntity = props.entity
  const target = props.target

  const N = model.const.Name
  const PROJECTNAME = envName(model)

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n    '${PROJECTNAME}_APIKEY' => '',`
    : ''
  const apikeyLiveField = authActive
    ? `\n      'apikey' => $env->{'${PROJECTNAME}_APIKEY'},`
    : ''

  // A templated server URL (OpenAPI server variables) makes a LIVE client
  // impossible to construct without values: makeOptions raises rather than
  // request a URL with a literal `{account_id}` in it. So the live suite
  // takes them from the environment the same way it takes the apikey.
  const svars = serverVariables(model)
  const serverEnvEntry = svars
    .map((v: any) => `\n    '${serverVarEnv(PROJECTNAME, v.name)}' => ${perlStringLiteral(v.dflt)},`).join('')
  const serverLiveField = 0 === svars.length ? '' : `
      'server' => {${svars
      .map((v: any) => `
        '${v.name}' => $env->{'${serverVarEnv(PROJECTNAME, v.name)}'},`).join('')}
      },`

  const opnames = Object.keys(entity.op || {})
  const hasLoad = opnames.includes('load')
  const hasList = opnames.includes('list')

  if (!hasLoad && !hasList) {
    return
  }

  const loadOp = entity.op?.load
  const listOp = entity.op?.list

  const loadPoint = loadOp?.points?.[0]
  const loadPath = loadPoint ? normalizePathParams(pointParts(loadPoint), loadPoint?.g?.params || [], loadPoint?.r?.param) : ''
  const allLoadParams = loadPoint?.g?.params || []
  // Only path params that actually appear in the URL template drive direct-
  // test path-param setup and URL-substitution asserts (see TestDirect_rb).
  const _pathPlaceholders = new Set<string>()
  for (const part of pointParts(loadPoint)) {
    if (typeof part === 'string' && part.startsWith('{') && part.endsWith('}')) {
      _pathPlaceholders.add(part.slice(1, -1))
    }
  }
  const _renameMap = (loadPoint?.r?.param || {}) as Record<string, string>
  const _renamedPlaceholders = new Set<string>()
  for (const ph of _pathPlaceholders) {
    _renamedPlaceholders.add(ph)
    for (const [orig, renamed] of Object.entries(_renameMap)) {
      if (renamed === ph) _renamedPlaceholders.add(orig)
    }
  }
  const loadParams = allLoadParams.filter((p: any) =>
    _renamedPlaceholders.has(p.n) || _renamedPlaceholders.has(p.or))

  const listPoint = listOp?.points?.[0]
  const listPath = listPoint ? normalizePathParams(pointParts(listPoint), listPoint?.g?.params || [], listPoint?.r?.param) : ''
  const listParams = listPoint?.g?.params || []

  // Required query params with spec-provided examples - needed in live mode.
  const loadQuery = loadPoint?.g?.query || []
  const loadLiveQueryEntries = loadQuery
    .filter((q: any) => q.r && undefined !== q.ex && null !== q.ex)
  const loadLiveQueryLines = loadLiveQueryEntries
    .map((q: any) => `    $query->{'${q.n}'} = ${perlScalar(q.ex)};`)
    .join('\n')

  const loadAllHaveExamples =
    loadParams.length > 0 &&
    loadParams.every((p: any) => undefined !== p.ex && null !== p.ex)
  const loadExampleLines = loadAllHaveExamples
    ? loadParams.map((p: any) => `    $params->{'${p.n}'} = ${perlScalar(p.ex)};`).join('\n')
    : ''

  const entidEnvVar = `${PROJECTNAME}_TEST_${envToken(entity.name)}_ENTID`

  // The *_ENTID key a live test reads a parameter's value from.
  const liveKey = (param: any): string =>
    ('id' === param.n ? entity.name : param.n.replace(/_id$/, '')) + '01'

  File({ name: entity.name + '_direct.t' }, () => {

    Content(`#!perl
# ${entity.Name} direct test

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd ();

use ${N}SDK;
require(Cwd::abs_path("$FindBin::Bin/runner.pm"));

${liveStrictNote(liveStrict(model, target.name), '#')}
use constant LIVE_STRICT => ${liveStrict(model, target.name) ? 1 : 0};

sub live_ok {
  my ($result) = @_;
  my $status = ${N}Helpers::to_int($result->{status});
  return !defined $result->{err} && $result->{ok} && $status >= 200 && $status < 300;
}

`)

    if (hasList && listPoint) {
      const label = 'direct-list-' + entity.name
      Content(`DIRECT_LIST: {
  my $setup = ${entity.name}_direct_setup([
    { 'id' => 'direct01' },
    { 'id' => 'direct02' },
  ]);
  my ($_should_skip, $_reason) = ${N}TestRunner::is_control_skipped(
    'direct', '${label}', $setup->{live} ? 'live' : 'unit');
  if ($_should_skip) {
    note($_reason || 'skipped via sdk-test-control.json');
    pass('${label}: skipped via sdk-test-control.json');
    last DIRECT_LIST;
  }
${liveKeysBlock(N, label, 'DIRECT_LIST', listParams.map(liveKey), entidEnvVar)}  my $client = $setup->{client};

  my $params = {};
`)
      listParams.forEach((lp: any, i: number) => {
        Content(`  $params->{'${lp.n}'} = $setup->{live} ? $setup->{idmap}{'${liveKey(lp)}'} : 'direct0${i + 1}';
`)
      })
      Content(`
  my $result = $client->direct({
    'path' => '${listPath}',
    'method' => 'GET',
    'params' => $params,
  });
  if ($setup->{live}) {
    if (!live_ok($result)) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live list failed: ' . ${N}TestRunner::live_describe($result));
      last DIRECT_LIST;
    }
    if (!defined ${N}TestRunner::live_list($result->{data})) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live list returned no list: ' . ${N}TestRunner::live_describe($result));
      last DIRECT_LIST;
    }
    pass('${label}: live ok');
  }
  else {
    ok(!defined $result->{err}, '${label}: no error');
    ok($result->{ok}, '${label}: ok');
    is(${N}Helpers::to_int($result->{status}), 200, '${label}: status');
    ok(Voxgig::Struct::islist($result->{data}), '${label}: data is array');
    is(scalar @{ $result->{data} }, 2, '${label}: data length');
    is(scalar @{ $setup->{calls} }, 1, '${label}: 1 call');
  }
}

`)
    }

    if (hasLoad && loadPoint) {
      const label = 'direct-load-' + entity.name
      const discover = !loadAllHaveExamples && hasList && 0 < loadParams.length
      const idParam = loadParams.find((p: any) => 'id' === p.n)?.n ?? loadParams[0]?.n ?? 'id'
      const loadLiveIdKeys: string[] = loadAllHaveExamples ? [] :
        discover ? listParams.map(liveKey).concat(loadParams.filter((p: any) => idParam !== p.n).map(liveKey)) :
          loadParams.map(liveKey)
      Content(`DIRECT_LOAD: {
  my $setup = ${entity.name}_direct_setup({ 'id' => 'direct01' });
  my ($_should_skip, $_reason) = ${N}TestRunner::is_control_skipped(
    'direct', '${label}', $setup->{live} ? 'live' : 'unit');
  if ($_should_skip) {
    note($_reason || 'skipped via sdk-test-control.json');
    pass('${label}: skipped via sdk-test-control.json');
    last DIRECT_LOAD;
  }
${liveKeysBlock(N, label, 'DIRECT_LOAD', [...new Set(loadLiveIdKeys)], entidEnvVar)}  my $client = $setup->{client};

  my $params = {};
  my $query = {};
  if ($setup->{live}) {
${loadLiveQueryLines ? loadLiveQueryLines + '\n' : ''}`)
      if (loadAllHaveExamples) {
        Content(loadExampleLines + '\n')
      }
      else if (discover) {
        Content(`    my $list_result = $client->direct({
      'path' => '${listPath}',
      'method' => 'GET',
      'params' => {${listParams.map((p: any) => `'${p.n}' => $setup->{idmap}{'${liveKey(p)}'}`).join(', ')}},
    });
    if (!live_ok($list_result)) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live list discovery failed: ' . ${N}TestRunner::live_describe($list_result));
      last DIRECT_LOAD;
    }
    my $records = ${N}TestRunner::live_list($list_result->{data});
    if (!defined $records) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live list discovery returned no list: ' . ${N}TestRunner::live_describe($list_result));
      last DIRECT_LOAD;
    }
    if (!@$records) {
      ${N}TestRunner::live_empty('${label}', 'The account has no ${entity.name} record to load');
      last DIRECT_LOAD;
    }
    my $first = ref $records->[0] eq 'HASH' ? $records->[0] : {};
    my $found = $first->{'${idParam}'} // $first->{'id'};
    if (!defined $found) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live load blocked: discovery returned no usable identity');
      last DIRECT_LOAD;
    }
    $params->{'${idParam}'} = $found;
`)
        for (const p of loadParams.filter((p: any) => idParam !== p.n)) {
          Content(`    $params->{'${p.n}'} = $setup->{idmap}{'${liveKey(p)}'};
`)
        }
      }
      else {
        for (const p of loadParams) {
          Content(`    $params->{'${p.n}'} = $setup->{idmap}{'${liveKey(p)}'};
`)
        }
      }
      Content(`  }
  else {
`)
      for (let i = 0; i < loadParams.length; i++) {
        Content(`    $params->{'${loadParams[i].n}'} = 'direct0${i + 1}';
`)
      }
      Content(`  }

  my $result = $client->direct({
    'path' => '${loadPath}',
    'method' => 'GET',
    'params' => $params,
    'query' => $query,
  });
  if ($setup->{live}) {
    if (!live_ok($result)) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live load failed: ' . ${N}TestRunner::live_describe($result));
      last DIRECT_LOAD;
    }
    if (!defined $result->{data}) {
      ${N}TestRunner::live_miss(LIVE_STRICT, '${label}', 'Live load returned no data: ' . ${N}TestRunner::live_describe($result));
      last DIRECT_LOAD;
    }
    pass('${label}: live ok');
  }
  else {
    ok(!defined $result->{err}, '${label}: no error');
    ok($result->{ok}, '${label}: ok');
    is(${N}Helpers::to_int($result->{status}), 200, '${label}: status');
    ok(defined $result->{data}, '${label}: data');
    if (Voxgig::Struct::ismap($result->{data})) {
      is($result->{data}{id}, 'direct01', '${label}: id');
    }
    is(scalar @{ $setup->{calls} }, 1, '${label}: 1 call');
  }
}

`)
    }

    Content(`
sub ${entity.name}_direct_setup {
  my ($mockres) = @_;
  ${N}TestRunner::load_env_local();

  my $calls = [];

  my $env = ${N}TestRunner::env_override({
    '${entidEnvVar}' => {},
    '${PROJECTNAME}_TEST_LIVE' => 'FALSE',${apikeyEnvEntry}${serverEnvEntry}
  });

  my $live = ((($env->{'${PROJECTNAME}_TEST_LIVE'}) || '') eq 'TRUE') ? 1 : 0;

  if ($live) {
    # live_client_options() FIRST so the generated fields below win:
    # sdk-test-control.json's test.client.options adds to the live client,
    # it does not redirect it (a later key wins in a Perl hash literal).
    my $client = ${N}SDK->new({
      %{ ${N}TestRunner::live_client_options() },${apikeyLiveField}${serverLiveField}
    });
    my $idmap = $env->{'${entidEnvVar}'};
    return {
      'client' => $client,
      'calls' => $calls,
      'live' => 1,
      'idmap' => ref $idmap eq 'HASH' ? $idmap : {},
    };
  }

  my $mock_fetch = sub {
    my ($url, $init) = @_;
    push @$calls, { 'url' => $url, 'init' => $init };
    return ({
      'status' => 200,
      'statusText' => 'OK',
      'headers' => {},
      'json' => sub {
        return defined $mockres ? $mockres : { 'id' => 'direct01' };
      },
      'body' => 'mock',
    }, undef);
  };

  my $client = ${N}SDK->new({
    'base' => 'http://localhost:8080',
    'system' => {
      'fetch' => $mock_fetch,
    },
  });

  return {
    'client' => $client,
    'calls' => $calls,
    'live' => 0,
    'idmap' => {},
  };
}

done_testing();
`)
  })
})


export {
  TestDirect
}
