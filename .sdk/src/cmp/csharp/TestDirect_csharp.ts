
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

import { formatCsValue } from './utility_csharp'


// Replace raw OpenAPI parameter names in path parts with model parameter
// names (mirrors TestDirect_go's normalizePathParams).
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


const TestDirect = cmp(function TestDirect(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity

  const Name = model.const.Name
  const PROJECTNAME = envName(model)
  const ENTUPPER = envToken(entity.name)

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n            ["${PROJECTNAME}_APIKEY"] = "NONE",`
    : ''
  const apikeyLiveField = authActive
    ? `\n                ["apikey"] = env["${PROJECTNAME}_APIKEY"],`
    : ''

  const opnames = Object.keys(entity.op || {})
  const hasLoad = opnames.includes('load')
  const hasList = opnames.includes('list')

  if (!hasLoad && !hasList) {
    return
  }

  const loadOp = entity.op?.load
  const listOp = entity.op?.list

  // Get load point info
  const loadPoint = loadOp?.points?.[0]
  const loadPath = loadPoint ? normalizePathParams(loadPoint.parts || [], loadPoint?.args?.params || [], loadPoint?.rename?.param) : ''
  const allLoadParams = loadPoint?.args?.params || []
  // Only path params that actually appear in the URL template drive direct
  // path-param setup and URL-substitution asserts.
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

  // Get list point info
  const listPoint = listOp?.points?.[0]
  const listPath = listPoint ? normalizePathParams(listPoint.parts || [], listPoint?.args?.params || [], listPoint?.rename?.param) : ''
  const listParams = listPoint?.args?.params || []

  // Required query params with spec-provided examples - needed in live mode.
  const loadQuery = loadPoint?.args?.query || []
  const loadLiveQueryEntries = loadQuery
    .filter((q: any) => q.reqd && undefined !== q.example && null !== q.example)
  const loadLiveQueryLines = loadLiveQueryEntries
    .map((q: any) => `            query["${q.name}"] = ${formatCsValue(q.example)};`)
    .join('\n')

  // Path params with spec-provided examples - when ALL load params have
  // spec examples, prefer them over list-bootstrap in live mode.
  const loadAllHaveExamples =
    loadParams.length > 0 &&
    loadParams.every((p: any) => undefined !== p.example && null !== p.example)
  const loadExampleLines = loadAllHaveExamples
    ? loadParams.map((p: any) =>
      `            pathParams["${p.name}"] = ${formatCsValue(p.example)};`).join('\n')
    : ''

  const entidEnvVar = `${PROJECTNAME}_TEST_${ENTUPPER}_ENTID`

  File({ name: entity.Name + 'DirectTest.' + target.ext }, () => {

    Content(`// ${entity.name} direct API tests (generated from the API model).

using System.Text.Json;

using Voxgig.Struct;
using Xunit;

namespace ${Name}Sdk.Test;

public class ${entity.Name}DirectTest
{
`)

    // Generate list test first (load needs list results in live mode)
    if (hasList && listPoint) {
      // Build live params for list
      const listLiveParams = listParams.map((p: any) => {
        const key = p.name === 'id'
          ? entity.name + '01'
          : p.name.replace(/_id$/, '') + '01'
        return { name: p.name, key }
      })

      const listLiveIdKeys = listParams.length > 0
        ? listLiveParams.map((lp: any) => lp.key)
        : []
      const listSkipBlock = listLiveIdKeys.length > 0
        ? `        if (setup.Live)
        {
            foreach (var _liveKey in new[] { ${listLiveIdKeys.map((k: string) => `"${k}"`).join(', ')} })
            {
                if (StructUtils.GetProp(setup.Idmap, _liveKey) == null)
                {
                    return; // live test needs *_ENTID env var (synthetic IDs only)
                }
            }
        }
`
        : ''

      Content(`    [Fact]
    public void DirectList()
    {
        var setup = ${entity.Name}DirectSetup(new List<object?>
        {
            new Dictionary<string, object?> { ["id"] = "direct01" },
            new Dictionary<string, object?> { ["id"] = "direct02" },
        });
        var _mode = setup.Live ? "live" : "unit";
        var (_shouldSkip, _) = TestRunner.IsControlSkipped(
            "direct", "direct-list-${entity.name}", _mode);
        if (_shouldSkip)
        {
            return; // skipped via sdk-test-control.json
        }
${listSkipBlock}        var client = setup.Client;

`)

      if (listParams.length > 0) {
        Content(`        var pathParams = new Dictionary<string, object?>();
`)
        listLiveParams.forEach((lp: any, i: number) => {
          const placeholder = 'direct0' + (i + 1)
          Content(`        if (setup.Live)
        {
            pathParams["${lp.name}"] = setup.Idmap["${lp.key}"];
        }
        else
        {
            pathParams["${lp.name}"] = "${placeholder}";
        }
`)
        })
        Content(`
        var result = client.Direct(new Dictionary<string, object?>
        {
            ["path"] = "${listPath}",
            ["method"] = "GET",
            ["params"] = pathParams,
        });
`)
      } else {
        Content(`
        var result = client.Direct(new Dictionary<string, object?>
        {
            ["path"] = "${listPath}",
            ["method"] = "GET",
            ["params"] = new Dictionary<string, object?>(),
        });
`)
      }

      Content(`        if (setup.Live)
        {
            // Live mode is lenient: synthetic IDs frequently 4xx and the
            // list-response shape varies wildly across public APIs. Bail
            // rather than fail when the call doesn't return a usable list.
            if (!Equals(result["ok"], true))
            {
                return;
            }
            var status = Helpers.ToInt(result["status"]);
            if (status < 200 || status >= 300)
            {
                return;
            }
        }
        else
        {
            Assert.True(Equals(result["ok"], true),
                $"expected ok to be true, got {result.GetValueOrDefault("err")}");
            Assert.Equal(200, Helpers.ToInt(result["status"]));
        }

        if (!setup.Live)
        {
            var dataList = result["data"] as List<object?>;
            Assert.True(dataList != null, "expected data to be a list");
            Assert.Equal(2, dataList!.Count);

            Assert.True(setup.Calls.Count == 1,
                $"expected 1 call, got {setup.Calls.Count}");
`)

      if (listParams.length > 0) {
        Content(`            var call = setup.Calls[0];
            var init = call["init"] as Dictionary<string, object?>;
            Assert.Equal("GET", init?["method"]);
            var url = call["url"] as string ?? "";
`)
        for (let i = 0; i < listParams.length; i++) {
          Content(`            Assert.Contains("direct0${i + 1}", url);
`)
        }
      }

      Content(`        }
    }

`)
    }

    // Generate load test - in live mode, first list to get a real entity ID
    if (hasLoad && loadPoint) {
      // Identify ancestor params (not 'id') for live mode
      const ancestorParams = loadParams.filter((p: any) => p.name !== 'id')

      let loadLiveIdKeys: string[] = []
      if (loadParams.length > 0 && !loadAllHaveExamples) {
        if (hasList) {
          loadLiveIdKeys = listParams.map((p: any) => {
            return p.name === 'id'
              ? entity.name + '01'
              : p.name.replace(/_id$/, '') + '01'
          })
        } else {
          loadLiveIdKeys = loadParams.map((p: any) => p.name + '01')
        }
      }
      const loadSkipBlock = loadLiveIdKeys.length > 0
        ? `        if (setup.Live)
        {
            foreach (var _liveKey in new[] { ${loadLiveIdKeys.map(k => `"${k}"`).join(', ')} })
            {
                if (StructUtils.GetProp(setup.Idmap, _liveKey) == null)
                {
                    return; // live test needs *_ENTID env var (synthetic IDs only)
                }
            }
        }
`
        : ''

      Content(`    [Fact]
    public void DirectLoad()
    {
        var setup = ${entity.Name}DirectSetup(
            new Dictionary<string, object?> { ["id"] = "direct01" });
        var _mode = setup.Live ? "live" : "unit";
        var (_shouldSkip, _) = TestRunner.IsControlSkipped(
            "direct", "direct-load-${entity.name}", _mode);
        if (_shouldSkip)
        {
            return; // skipped via sdk-test-control.json
        }
${loadSkipBlock}        var client = setup.Client;

`)

      const needsQuery = loadParams.length > 0 || loadLiveQueryLines !== ''
      if (needsQuery) {
        Content(`        var pathParams = new Dictionary<string, object?>();
        var query = new Dictionary<string, object?>();
`)

        Content(`        if (setup.Live)
        {
`)

        if (loadLiveQueryLines) {
          Content(loadLiveQueryLines + '\n')
        }

        if (loadAllHaveExamples) {
          Content(loadExampleLines + '\n')
        } else if (hasList && loadParams.length > 0) {
          // List-bootstrap: first call list, take id from response.
          Content(`            var listParams = new Dictionary<string, object?>();
`)
          for (const p of listParams) {
            const key = p.name === 'id'
              ? entity.name + '01'
              : p.name.replace(/_id$/, '') + '01'
            Content(`            listParams["${p.name}"] = setup.Idmap["${key}"];
`)
          }

          Content(`            var listResult = client.Direct(new Dictionary<string, object?>
            {
                ["path"] = "${listPath}",
                ["method"] = "GET",
                ["params"] = listParams,
            });
            if (!Equals(listResult["ok"], true))
            {
                return; // list call not ok (likely synthetic IDs)
            }

            // Get first entity ID from list
            var listData = listResult["data"] as List<object?>;
            if (listData == null || listData.Count == 0)
            {
                return; // no entities to load in live mode
            }
            var firstEnt = Helpers.ToMapAny(listData[0]);
            pathParams["id"] = firstEnt?["id"];
`)
          for (const p of ancestorParams) {
            const key = p.name.replace(/_id$/, '') + '01'
            Content(`            pathParams["${p.name}"] = setup.Idmap["${key}"];
`)
          }
        }

        if (loadParams.length > 0) {
          Content(`        }
        else
        {
`)
          for (let i = 0; i < loadParams.length; i++) {
            Content(`            pathParams["${loadParams[i].name}"] = "direct0${i + 1}";
`)
          }
        }
        Content(`        }
`)
      }

      Content(`
        var result = client.Direct(new Dictionary<string, object?>
        {
            ["path"] = "${loadPath}",
            ["method"] = "GET",
`)
      if (needsQuery) {
        Content(`            ["params"] = pathParams,
            ["query"] = query,
`)
      } else {
        Content(`            ["params"] = new Dictionary<string, object?>(),
`)
      }
      Content(`        });
        if (setup.Live)
        {
            // Live mode is lenient: synthetic IDs frequently 4xx. Bail
            // rather than fail when the load endpoint isn't reachable.
            if (!Equals(result["ok"], true))
            {
                return;
            }
            var status = Helpers.ToInt(result["status"]);
            if (status < 200 || status >= 300)
            {
                return;
            }
            Assert.NotNull(result["data"]);
        }
        else
        {
            Assert.True(Equals(result["ok"], true),
                $"expected ok to be true, got {result.GetValueOrDefault("err")}");
            Assert.Equal(200, Helpers.ToInt(result["status"]));
            Assert.NotNull(result["data"]);
        }

        if (!setup.Live)
        {
            if (result["data"] is Dictionary<string, object?> dataMap)
            {
                Assert.True(Equals(dataMap["id"], "direct01"),
                    $"expected data.id to be direct01, got {dataMap["id"]}");
            }

            Assert.True(setup.Calls.Count == 1,
                $"expected 1 call, got {setup.Calls.Count}");
            var call = setup.Calls[0];
            var init = call["init"] as Dictionary<string, object?>;
            Assert.Equal("GET", init?["method"]);
            var url = call["url"] as string ?? "";
`)

      for (let i = 0; i < loadParams.length; i++) {
        Content(`            Assert.Contains("direct0${i + 1}", url);
`)
      }

      Content(`        }
    }

`)
    }

    Content(`    private class ${entity.Name}DirectSetupResult
    {
        public ${Name}SDK Client = null!;
        public List<Dictionary<string, object?>> Calls = new();
        public bool Live;
        public Dictionary<string, object?> Idmap = new();
    }

    private static ${entity.Name}DirectSetupResult ${entity.Name}DirectSetup(object? mockres)
    {
        TestRunner.LoadEnvLocal();

        var calls = new List<Dictionary<string, object?>>();

        var env = TestRunner.EnvOverride(new Dictionary<string, object?>
        {
            ["${entidEnvVar}"] = new Dictionary<string, object?>(),
            ["${PROJECTNAME}_TEST_LIVE"] = "FALSE",${apikeyEnvEntry}
        });

        var live = Equals(env["${PROJECTNAME}_TEST_LIVE"], "TRUE");

        if (live)
        {
            var liveClient = new ${Name}SDK(new Dictionary<string, object?>
            {${apikeyLiveField}
            });

            var idmap = new Dictionary<string, object?>();
            var entidRaw = env["${entidEnvVar}"];
            if (entidRaw is string entidStr && entidStr.StartsWith("{"))
            {
                try
                {
                    var el = JsonSerializer.Deserialize<JsonElement>(entidStr);
                    idmap = StructRunner.ConvertElement(el)
                        as Dictionary<string, object?> ?? idmap;
                }
                catch (JsonException)
                {
                }
            }
            else if (entidRaw is Dictionary<string, object?> entidMap)
            {
                idmap = entidMap;
            }

            return new ${entity.Name}DirectSetupResult
            {
                Client = liveClient,
                Calls = calls,
                Live = true,
                Idmap = idmap,
            };
        }

        Func<string, Dictionary<string, object?>, Dictionary<string, object?>> mockFetch =
            (url, init) =>
            {
                calls.Add(new Dictionary<string, object?>
                {
                    ["url"] = url,
                    ["init"] = init,
                });
                return new Dictionary<string, object?>
                {
                    ["status"] = 200,
                    ["statusText"] = "OK",
                    ["headers"] = new Dictionary<string, object?>(),
                    ["json"] = (Func<object?>)(() =>
                        mockres ?? new Dictionary<string, object?> { ["id"] = "direct01" }),
                };
            };

        var client = new ${Name}SDK(new Dictionary<string, object?>
        {
            ["base"] = "http://localhost:8080",
            ["system"] = new Dictionary<string, object?>
            {
                ["fetch"] = mockFetch,
            },
        });

        return new ${entity.Name}DirectSetupResult
        {
            Client = client,
            Calls = calls,
            Live = false,
            Idmap = new Dictionary<string, object?>(),
        };
    }
}
`)
  })
})


export {
  TestDirect
}
