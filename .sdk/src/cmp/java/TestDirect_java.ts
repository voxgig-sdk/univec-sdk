
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


// Replace raw OpenAPI parameter names in path parts with model parameter names.
// Path parts may have e.g. {subBreed} while model params use sub_breed.
// When a rename mapping exists (e.g. closureId -> id), path parts contain the
// renamed form {id} but params still use the original name closure_id.
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


// Render a JSON value as a Java literal for query examples.
// A Java source literal for an example value from the model.
//
// An integer beyond Java's int range needs the L suffix: javac rejects a bare
// 120615523104 outright ("integer number too large"), so one large id in a
// spec's example makes the whole generated test package fail to compile.
// A non-integral double is fine unsuffixed.
function javaLiteral(v: any): string {
  if (null == v) return 'null'
  if ('boolean' === typeof v) return String(v)
  if ('number' === typeof v) {
    if (Number.isInteger(v) && (v > 2147483647 || v < -2147483648)) {
      return String(v) + 'L'
    }
    return String(v)
  }
  return JSON.stringify(String(v))
}


const TestDirect = cmp(function TestDirect(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity
  const javapackage: string = props.javapackage

  const PROJECTNAME = envName(model)
  const SDK = model.const.Name + 'SDK'

  const authActive = isAuthActive(model)

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
  // Only path params that actually appear in the URL template drive
  // direct-test path-param setup and URL-substitution asserts.
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

  // Required query params with spec-provided examples — needed in live mode.
  const loadQuery = loadPoint?.args?.query || []
  const loadLiveQueryEntries = loadQuery
    .filter((q: any) => q.reqd && undefined !== q.example && null !== q.example)
  const loadLiveQueryLines = loadLiveQueryEntries
    .map((q: any) => `      query.put("${q.name}", ${javaLiteral(q.example)});`)
    .join('\n')

  // Path params with spec-provided examples — when ALL load params have
  // spec examples, prefer them over list-bootstrap.
  const loadAllHaveExamples =
    loadParams.length > 0 &&
    loadParams.every((p: any) => undefined !== p.example && null !== p.example)
  const loadExampleLines = loadAllHaveExamples
    ? loadParams.map((p: any) => `      params.put("${p.name}", ${javaLiteral(p.example)});`).join('\n')
    : ''

  // Build the ENTID env var name for this entity
  const entidEnvVar = `${PROJECTNAME}_TEST_${envToken(entity.name)}_ENTID`

  File({ name: entity.Name + 'DirectTest.' + target.ext }, () => {

    Content(`package ${javapackage}.sdktest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BiFunction;
import java.util.function.Supplier;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import ${javapackage}.core.Helpers;
import ${javapackage}.core.${SDK};
import ${javapackage}.utility.Json;

@SuppressWarnings({"unchecked", "unused"})
public class ${entity.Name}DirectTest {

  static Map<String, Object> jm(Object... kv) {
    Map<String, Object> out = new LinkedHashMap<>();
    for (int i = 0; i < kv.length - 1; i += 2) {
      out.put(String.valueOf(kv[i]), kv[i + 1]);
    }
    return out;
  }

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
        ? `    if (setup.live) {
      for (String liveKey : new String[] { ${listLiveIdKeys.map((k: string) => `"${k}"`).join(', ')} }) {
        Assumptions.assumeTrue(setup.idmap.get(liveKey) != null,
            "live test needs " + liveKey + " via *_ENTID env var (synthetic IDs only)");
      }
    }
`
        : ''

      Content(`  @Test
  public void directList${entity.Name}() {
    List<Object> mockres = new ArrayList<>();
    mockres.add(jm("id", "direct01"));
    mockres.add(jm("id", "direct02"));
    DirectSetup setup = directSetup(mockres);
    String mode = setup.live ? "live" : "unit";
    String reason = RunnerSupport.skipReason("direct", "direct-list-${entity.name}", mode);
    Assumptions.assumeTrue(reason == null,
        reason == null || "".equals(reason)
            ? "skipped via sdk-test-control.json" : reason);
${listSkipBlock}    ${SDK} client = setup.client;

`)

      if (listParams.length > 0) {
        Content(`    Map<String, Object> params = new LinkedHashMap<>();
`)
        listLiveParams.forEach((lp: any, i: number) => {
          const placeholder = 'direct0' + (i + 1)
          Content(`    if (setup.live) {
      params.put("${lp.name}", setup.idmap.get("${lp.key}"));
    }
    else {
      params.put("${lp.name}", "${placeholder}");
    }
`)
        })
        Content(`
    Map<String, Object> result = client.direct(jm(
        "path", "${listPath}",
        "method", "GET",
        "params", params));
`)
      } else {
        Content(`
    Map<String, Object> result = client.direct(jm(
        "path", "${listPath}",
        "method", "GET",
        "params", new LinkedHashMap<>()));
`)
      }

      Content(`    if (setup.live) {
      // Live mode is lenient: synthetic IDs frequently 4xx and the
      // list-response shape varies wildly across public APIs. Skip
      // rather than fail when the call doesn't return a usable list.
      Assumptions.assumeTrue(Boolean.TRUE.equals(result.get("ok")),
          "list call not ok (likely synthetic IDs against live API): " + result);
      int status = Helpers.toInt(result.get("status"));
      Assumptions.assumeTrue(status >= 200 && status < 300,
          "expected 2xx status, got " + result.get("status"));
    }
    else {
      assertEquals(true, result.get("ok"), "expected ok to be true");
      assertEquals(200, Helpers.toInt(result.get("status")), "expected status 200");
    }

    if (!setup.live) {
      assertTrue(result.get("data") instanceof List,
          "expected data to be an array, got " + result.get("data"));
      assertEquals(2, ((List<Object>) result.get("data")).size(), "expected 2 items");

      assertEquals(1, setup.calls.size(), "expected 1 call");
`)

      if (listParams.length > 0) {
        Content(`      Map<String, Object> call = setup.calls.get(0);
      Map<String, Object> initMap = Helpers.toMapAny(call.get("init"));
      if (initMap != null) {
        assertEquals("GET", initMap.get("method"), "expected method GET");
      }
      String url = call.get("url") instanceof String ? (String) call.get("url") : "";
`)
        for (let i = 0; i < listParams.length; i++) {
          Content(`      assertTrue(url.contains("direct0${i + 1}"),
          "expected url to contain direct0${i + 1}, got " + url);
`)
        }
      }

      Content(`    }
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
        ? `    if (setup.live) {
      for (String liveKey : new String[] { ${loadLiveIdKeys.map(k => `"${k}"`).join(', ')} }) {
        Assumptions.assumeTrue(setup.idmap.get(liveKey) != null,
            "live test needs " + liveKey + " via *_ENTID env var (synthetic IDs only)");
      }
    }
`
        : ''

      Content(`  @Test
  public void directLoad${entity.Name}() {
    DirectSetup setup = directSetup(jm("id", "direct01"));
    String mode = setup.live ? "live" : "unit";
    String reason = RunnerSupport.skipReason("direct", "direct-load-${entity.name}", mode);
    Assumptions.assumeTrue(reason == null,
        reason == null || "".equals(reason)
            ? "skipped via sdk-test-control.json" : reason);
${loadSkipBlock}    ${SDK} client = setup.client;

`)

      const needsQuery = loadParams.length > 0 || loadLiveQueryLines !== ''
      if (needsQuery) {
        Content(`    Map<String, Object> params = new LinkedHashMap<>();
    Map<String, Object> query = new LinkedHashMap<>();
`)

        Content(`    if (setup.live) {
`)

        if (loadLiveQueryLines) {
          Content(loadLiveQueryLines + '\n')
        }

        if (loadAllHaveExamples) {
          Content(loadExampleLines + '\n')
        } else if (hasList && loadParams.length > 0) {
          Content(`      Map<String, Object> listParams = new LinkedHashMap<>();
`)
          for (const p of listParams) {
            const key = p.name === 'id'
              ? entity.name + '01'
              : p.name.replace(/_id$/, '') + '01'
            Content(`      listParams.put("${p.name}", setup.idmap.get("${key}"));
`)
          }

          Content(`      Map<String, Object> listResult = client.direct(jm(
          "path", "${listPath}",
          "method", "GET",
          "params", listParams));
      Assumptions.assumeTrue(Boolean.TRUE.equals(listResult.get("ok")),
          "list call not ok (likely synthetic IDs against live API): " + listResult);

      // Get first entity ID from list
      List<Object> listData = listResult.get("data") instanceof List
          ? (List<Object>) listResult.get("data") : new ArrayList<>();
      Assumptions.assumeTrue(!listData.isEmpty(), "no entities to load in live mode");
      Map<String, Object> firstEnt = Helpers.toMapAny(listData.get(0));
      params.put("id", firstEnt.get("id"));
`)
          for (const p of ancestorParams) {
            const key = p.name.replace(/_id$/, '') + '01'
            Content(`      params.put("${p.name}", setup.idmap.get("${key}"));
`)
          }
        }

        if (loadParams.length > 0) {
          Content(`    }
    else {
`)
          for (let i = 0; i < loadParams.length; i++) {
            Content(`      params.put("${loadParams[i].name}", "direct0${i + 1}");
`)
          }
        }
        Content(`    }
`)
      }

      if (needsQuery) {
        Content(`
    Map<String, Object> result = client.direct(jm(
        "path", "${loadPath}",
        "method", "GET",
        "params", params,
        "query", query));
`)
      } else {
        Content(`
    Map<String, Object> result = client.direct(jm(
        "path", "${loadPath}",
        "method", "GET",
        "params", new LinkedHashMap<>()));
`)
      }

      Content(`    if (setup.live) {
      // Live mode is lenient: synthetic IDs frequently 4xx. Skip rather
      // than fail when the load endpoint isn't reachable with the IDs we
      // can construct from setup.idmap.
      Assumptions.assumeTrue(Boolean.TRUE.equals(result.get("ok")),
          "load call not ok (likely synthetic IDs against live API): " + result);
      int status = Helpers.toInt(result.get("status"));
      Assumptions.assumeTrue(status >= 200 && status < 300,
          "expected 2xx status, got " + result.get("status"));
    }
    else {
      assertEquals(true, result.get("ok"), "expected ok to be true");
      assertEquals(200, Helpers.toInt(result.get("status")), "expected status 200");
      assertNotNull(result.get("data"), "expected data to be non-null");
    }

    if (!setup.live) {
      Map<String, Object> dataMap = Helpers.toMapAny(result.get("data"));
      if (dataMap != null) {
        assertEquals("direct01", dataMap.get("id"), "expected data.id to be direct01");
      }

      assertEquals(1, setup.calls.size(), "expected 1 call");
      Map<String, Object> call = setup.calls.get(0);
      Map<String, Object> initMap = Helpers.toMapAny(call.get("init"));
      if (initMap != null) {
        assertEquals("GET", initMap.get("method"), "expected method GET");
      }
      String url = call.get("url") instanceof String ? (String) call.get("url") : "";
`)

      for (let i = 0; i < loadParams.length; i++) {
        Content(`      assertTrue(url.contains("direct0${i + 1}"),
          "expected url to contain direct0${i + 1}, got " + url);
`)
      }

      Content(`    }
  }

`)
    }

    Content(`  static class DirectSetup {
    ${SDK} client;
    List<Map<String, Object>> calls;
    boolean live;
    Map<String, Object> idmap;
  }

  static DirectSetup directSetup(Object mockres) {
    RunnerSupport.loadEnvLocal();

    final List<Map<String, Object>> calls = new ArrayList<>();

    Map<String, Object> envm = new LinkedHashMap<>();
    envm.put("${entidEnvVar}", new LinkedHashMap<>());
    envm.put("${PROJECTNAME}_TEST_LIVE", "FALSE");
${authActive ? `    envm.put("${PROJECTNAME}_APIKEY", "NONE");\n` : ''}    Map<String, Object> env = RunnerSupport.envOverride(envm);

    boolean live = "TRUE".equals(env.get("${PROJECTNAME}_TEST_LIVE"));

    DirectSetup setup = new DirectSetup();
    setup.calls = calls;

    if (live) {
      Map<String, Object> mergedOpts = new LinkedHashMap<>();
${authActive ? `      mergedOpts.put("apikey", env.get("${PROJECTNAME}_APIKEY"));\n` : ''}      setup.client = new ${SDK}(mergedOpts);
      setup.live = true;

      Map<String, Object> idmap = new LinkedHashMap<>();
      Object entidRaw = env.get("${entidEnvVar}");
      if (entidRaw instanceof String && ((String) entidRaw).startsWith("{")) {
        Map<String, Object> parsed = Helpers.toMapAny(Json.parseOrNull((String) entidRaw));
        if (parsed != null) {
          idmap = parsed;
        }
      }
      else if (entidRaw instanceof Map) {
        idmap = (Map<String, Object>) entidRaw;
      }
      setup.idmap = idmap;
      return setup;
    }

    final Object mockdata = mockres != null ? mockres : jm("id", "direct01");
    BiFunction<String, Map<String, Object>, Map<String, Object>> mockFetch =
        (url, init) -> {
          calls.add(jm("url", url, "init", init));
          return jm(
              "status", 200,
              "statusText", "OK",
              "headers", new LinkedHashMap<>(),
              "json", (Supplier<Object>) () -> mockdata);
        };

    setup.client = new ${SDK}(jm(
        "base", "http://localhost:8080",
        "system", jm("fetch", mockFetch)));
    setup.live = false;
    setup.idmap = new LinkedHashMap<>();
    return setup;
  }
}
`)
  })
})


export {
  TestDirect
}
