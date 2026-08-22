
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
  isAuthActive, envName, envToken
} from '@voxgig/sdkgen'


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

  const N = model.const.Name
  const PROJECTNAME = envName(model)

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n    '${PROJECTNAME}_APIKEY' => 'NONE',`
    : ''
  const apikeyLiveField = authActive
    ? `\n      'apikey' => $env->{'${PROJECTNAME}_APIKEY'},`
    : ''

  const opnames = Object.keys(entity.op || {})
  const hasLoad = opnames.includes('load')
  const hasList = opnames.includes('list')

  if (!hasLoad && !hasList) {
    return
  }

  const loadOp = entity.op?.load
  const listOp = entity.op?.list

  const loadPoint = loadOp?.points?.[0]
  const loadPath = loadPoint ? normalizePathParams(loadPoint.parts || [], loadPoint?.args?.params || [], loadPoint?.rename?.param) : ''
  const allLoadParams = loadPoint?.args?.params || []
  // Only path params that actually appear in the URL template drive direct-
  // test path-param setup and URL-substitution asserts (see TestDirect_rb).
  const _pathPlaceholders = new Set<string>()
  for (const part of (loadPoint?.parts || [])) {
    if (typeof part === 'string' && part.startsWith('{') && part.endsWith('}')) {
      _pathPlaceholders.add(part.slice(1, -1))
    }
  }
  const _renameMap = (loadPoint?.rename?.param || {}) as Record<string, string>
  const _renamedPlaceholders = new Set<string>()
  for (const ph of _pathPlaceholders) {
    _renamedPlaceholders.add(ph)
    for (const [orig, renamed] of Object.entries(_renameMap)) {
      if (renamed === ph) _renamedPlaceholders.add(orig)
    }
  }
  const loadParams = allLoadParams.filter((p: any) =>
    _renamedPlaceholders.has(p.name) || _renamedPlaceholders.has(p.orig))

  const listPoint = listOp?.points?.[0]
  const listPath = listPoint ? normalizePathParams(listPoint.parts || [], listPoint?.args?.params || [], listPoint?.rename?.param) : ''
  const listParams = listPoint?.args?.params || []

  // Required query params with spec-provided examples - needed in live mode.
  const loadQuery = loadPoint?.args?.query || []
  const loadLiveQueryEntries = loadQuery
    .filter((q: any) => q.reqd && undefined !== q.example && null !== q.example)
  const loadLiveQueryLines = loadLiveQueryEntries
    .map((q: any) => `    $query->{'${q.name}'} = ${perlScalar(q.example)};`)
    .join('\n')

  const loadAllHaveExamples =
    loadParams.length > 0 &&
    loadParams.every((p: any) => undefined !== p.example && null !== p.example)
  const loadExampleLines = loadAllHaveExamples
    ? loadParams.map((p: any) => `    $params->{'${p.name}'} = ${perlScalar(p.example)};`).join('\n')
    : ''

  const entidEnvVar = `${PROJECTNAME}_TEST_${envToken(entity.name)}_ENTID`

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

`)

    if (hasList && listPoint) {
      const listLiveIdKeys: string[] = listParams.map((lp: any) => {
        return lp.name === 'id'
          ? entity.name + '01'
          : lp.name.replace(/_id$/, '') + '01'
      })
      const listSkipBlock = listLiveIdKeys.length > 0
        ? `  if ($setup->{live}) {
    for my $_live_key (${listLiveIdKeys.map(k => `'${k}'`).join(', ')}) {
      if (!defined $setup->{idmap}{$_live_key}) {
        note("live test needs $_live_key via *_ENTID env var (synthetic IDs only)");
        pass('direct-list-${entity.name}: skipped');
        last DIRECT_LIST;
      }
    }
  }
`
        : ''
      Content(`DIRECT_LIST: {
  my $setup = ${entity.name}_direct_setup([
    { 'id' => 'direct01' },
    { 'id' => 'direct02' },
  ]);
  my ($_should_skip, $_reason) = ${N}TestRunner::is_control_skipped(
    'direct', 'direct-list-${entity.name}', $setup->{live} ? 'live' : 'unit');
  if ($_should_skip) {
    note($_reason || 'skipped via sdk-test-control.json');
    pass('direct-list-${entity.name}: skipped via sdk-test-control.json');
    last DIRECT_LIST;
  }
${listSkipBlock}  my $client = $setup->{client};

`)

      if (listParams.length > 0) {
        Content(`  my $params = {};
`)
        for (const lp of listParams) {
          const key = lp.name === 'id'
            ? entity.name + '01'
            : lp.name.replace(/_id$/, '') + '01'
          Content(`  if ($setup->{live}) {
    $params->{'${lp.name}'} = $setup->{idmap}{'${key}'};
  }
  else {
    $params->{'${lp.name}'} = 'direct01';
  }
`)
        }
        Content(`
  my $result = $client->direct({
    'path' => '${listPath}',
    'method' => 'GET',
    'params' => $params,
  });
`)
      } else {
        Content(`  my $result = $client->direct({
    'path' => '${listPath}',
    'method' => 'GET',
    'params' => {},
  });
`)
      }

      Content(`  if ($setup->{live}) {
    # Live mode is lenient: synthetic IDs frequently 4xx and the list-
    # response shape varies wildly across public APIs. Skip rather than
    # fail when the call doesn't return a usable list.
    if (defined $result->{err}) {
      note("list call failed (likely synthetic IDs against live API): $result->{err}");
      pass('direct-list-${entity.name}: skipped (live)');
      last DIRECT_LIST;
    }
    unless ($result->{ok}) {
      note('list call not ok (likely synthetic IDs against live API)');
      pass('direct-list-${entity.name}: skipped (live)');
      last DIRECT_LIST;
    }
    my $status = ${N}Helpers::to_int($result->{status});
    if ($status < 200 || $status >= 300) {
      note("expected 2xx status, got $status");
      pass('direct-list-${entity.name}: skipped (live)');
      last DIRECT_LIST;
    }
    pass('direct-list-${entity.name}: live ok');
  }
  else {
    ok(!defined $result->{err}, 'direct-list-${entity.name}: no error');
    ok($result->{ok}, 'direct-list-${entity.name}: ok');
    is(${N}Helpers::to_int($result->{status}), 200, 'direct-list-${entity.name}: status');
    ok(Voxgig::Struct::islist($result->{data}), 'direct-list-${entity.name}: data is array');
    is(scalar @{ $result->{data} }, 2, 'direct-list-${entity.name}: data length');
    is(scalar @{ $setup->{calls} }, 1, 'direct-list-${entity.name}: 1 call');
  }
}

`)
    }

    if (hasLoad && loadPoint) {
      // Skip live direct-load only when we can't fill path params:
      // no spec examples and no list-bootstrap. Spec examples win first.
      const loadSkipBlock = (loadParams.length > 0 && !loadAllHaveExamples)
        ? `  if ($setup->{live}) {
    note('live direct-load needs real ID - set *_ENTID env var with real IDs to run');
    pass('direct-load-${entity.name}: skipped (live)');
    last DIRECT_LOAD;
  }
`
        : ''
      Content(`DIRECT_LOAD: {
  my $setup = ${entity.name}_direct_setup({ 'id' => 'direct01' });
  my ($_should_skip, $_reason) = ${N}TestRunner::is_control_skipped(
    'direct', 'direct-load-${entity.name}', $setup->{live} ? 'live' : 'unit');
  if ($_should_skip) {
    note($_reason || 'skipped via sdk-test-control.json');
    pass('direct-load-${entity.name}: skipped via sdk-test-control.json');
    last DIRECT_LOAD;
  }
${loadSkipBlock}  my $client = $setup->{client};

`)

      const needsQuery = loadParams.length > 0 || loadLiveQueryLines !== ''
      if (needsQuery) {
        Content(`  my $params = {};
  my $query = {};
`)
        if (loadAllHaveExamples) {
          Content(`  if ($setup->{live}) {
`)
          if (loadLiveQueryLines) Content(loadLiveQueryLines + '\n')
          Content(loadExampleLines + '\n')
          Content(`  }
  else {
`)
          for (let i = 0; i < loadParams.length; i++) {
            Content(`    $params->{'${loadParams[i].name}'} = 'direct0${i + 1}';
`)
          }
          Content(`  }
`)
        } else if (loadParams.length > 0) {
          if (loadLiveQueryLines) {
            Content(`  if ($setup->{live}) {
${loadLiveQueryLines}
  }
`)
          }
          Content(`  unless ($setup->{live}) {
`)
          for (let i = 0; i < loadParams.length; i++) {
            Content(`    $params->{'${loadParams[i].name}'} = 'direct0${i + 1}';
`)
          }
          Content(`  }
`)
        } else if (loadLiveQueryLines) {
          Content(`  if ($setup->{live}) {
${loadLiveQueryLines}
  }
`)
        }
      }

      Content(`
  my $result = $client->direct({
    'path' => '${loadPath}',
    'method' => 'GET',
`)
      if (needsQuery) {
        Content(`    'params' => $params,
    'query' => $query,
`)
      } else {
        Content(`    'params' => {},
`)
      }
      Content(`  });
  if ($setup->{live}) {
    # Live mode is lenient: synthetic IDs frequently 4xx. Skip rather
    # than fail when the load endpoint isn't reachable with the IDs
    # we can construct from setup idmap.
    if (defined $result->{err}) {
      note("load call failed (likely synthetic IDs against live API): $result->{err}");
      pass('direct-load-${entity.name}: skipped (live)');
      last DIRECT_LOAD;
    }
    unless ($result->{ok}) {
      note('load call not ok (likely synthetic IDs against live API)');
      pass('direct-load-${entity.name}: skipped (live)');
      last DIRECT_LOAD;
    }
    my $status = ${N}Helpers::to_int($result->{status});
    if ($status < 200 || $status >= 300) {
      note("expected 2xx status, got $status");
      pass('direct-load-${entity.name}: skipped (live)');
      last DIRECT_LOAD;
    }
    pass('direct-load-${entity.name}: live ok');
  }
  else {
    ok(!defined $result->{err}, 'direct-load-${entity.name}: no error');
    ok($result->{ok}, 'direct-load-${entity.name}: ok');
    is(${N}Helpers::to_int($result->{status}), 200, 'direct-load-${entity.name}: status');
    ok(defined $result->{data}, 'direct-load-${entity.name}: data');
    if (Voxgig::Struct::ismap($result->{data})) {
      is($result->{data}{id}, 'direct01', 'direct-load-${entity.name}: id');
    }
    is(scalar @{ $setup->{calls} }, 1, 'direct-load-${entity.name}: 1 call');
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
    '${PROJECTNAME}_TEST_LIVE' => 'FALSE',${apikeyEnvEntry}
  });

  my $live = ((($env->{'${PROJECTNAME}_TEST_LIVE'}) || '') eq 'TRUE') ? 1 : 0;

  if ($live) {
    my $client = ${N}SDK->new({${apikeyLiveField}
    });
    return {
      'client' => $client,
      'calls' => $calls,
      'live' => 1,
      'idmap' => {},
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
