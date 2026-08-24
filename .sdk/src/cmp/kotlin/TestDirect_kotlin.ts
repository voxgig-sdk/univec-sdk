
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


// Render a JSON value as a Kotlin literal for query examples.
function kotlinLiteral(v: any): string {
  if (null == v) return 'null'
  if ('number' === typeof v || 'boolean' === typeof v) return String(v)
  return JSON.stringify(String(v))
}


const TestDirect = cmp(function TestDirect(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity
  const kotlinpackage: string = props.kotlinpackage

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

  const loadPoint = loadOp?.points?.[0]
  const loadPath = loadPoint ? normalizePathParams(loadPoint.parts || [], loadPoint?.args?.params || [], loadPoint?.rename?.param) : ''
  const allLoadParams = loadPoint?.args?.params || []
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

  const loadQuery = loadPoint?.args?.query || []
  const loadLiveQueryEntries = loadQuery
    .filter((q: any) => q.reqd && undefined !== q.example && null !== q.example)
  const loadLiveQueryLines = loadLiveQueryEntries
    .map((q: any) => `      query["${q.name}"] = ${kotlinLiteral(q.example)}`)
    .join('\n')

  const loadAllHaveExamples =
    loadParams.length > 0 &&
    loadParams.every((p: any) => undefined !== p.example && null !== p.example)
  const loadExampleLines = loadAllHaveExamples
    ? loadParams.map((p: any) => `      params["${p.name}"] = ${kotlinLiteral(p.example)}`).join('\n')
    : ''

  const entidEnvVar = `${PROJECTNAME}_TEST_${envToken(entity.name)}_ENTID`

  File({ name: entity.Name + 'DirectTest.' + target.ext }, () => {

    Content(`package ${kotlinpackage}.sdktest

import java.util.function.BiFunction
import java.util.function.Supplier

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions
import org.junit.jupiter.api.Test

import ${kotlinpackage}.core.Helpers
import ${kotlinpackage}.core.${SDK}
import ${kotlinpackage}.utility.Json

@Suppress("UNCHECKED_CAST", "UNUSED_VARIABLE")
class ${entity.Name}DirectTest {

`)

    if (hasList && listPoint) {
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
      for (liveKey in arrayOf<String>(${listLiveIdKeys.map((k: string) => `"${k}"`).join(', ')})) {
        Assumptions.assumeTrue(setup.idmap[liveKey] != null,
            "live test needs " + liveKey + " via *_ENTID env var (synthetic IDs only)")
      }
    }
`
        : ''

      Content(`  @Test
  fun directList${entity.Name}() {
    val mockres = mutableListOf<Any?>()
    mockres.add(jm("id", "direct01"))
    mockres.add(jm("id", "direct02"))
    val setup = directSetup(mockres)
    val mode = if (setup.live) "live" else "unit"
    val reason = RunnerSupport.skipReason("direct", "direct-list-${entity.name}", mode)
    Assumptions.assumeTrue(
      reason == null,
      if (reason == null || "" == reason) "skipped via sdk-test-control.json" else reason,
    )
${listSkipBlock}    val client = setup.client

`)

      if (listParams.length > 0) {
        Content(`    val params = linkedMapOf<String, Any?>()
`)
        listLiveParams.forEach((lp: any, i: number) => {
          const placeholder = 'direct0' + (i + 1)
          Content(`    if (setup.live) {
      params["${lp.name}"] = setup.idmap["${lp.key}"]
    } else {
      params["${lp.name}"] = "${placeholder}"
    }
`)
        })
        Content(`
    val result = client.direct(jm(
        "path", "${listPath}",
        "method", "GET",
        "params", params))
`)
      } else {
        Content(`
    val result = client.direct(jm(
        "path", "${listPath}",
        "method", "GET",
        "params", linkedMapOf<String, Any?>()))
`)
      }

      Content(`    if (setup.live) {
      Assumptions.assumeTrue(result["ok"] == true,
          "list call not ok (likely synthetic IDs against live API): " + result)
      val status = Helpers.toInt(result["status"])
      Assumptions.assumeTrue(status in 200..299, "expected 2xx status, got " + result["status"])
    } else {
      assertEquals(true, result["ok"], "expected ok to be true")
      assertEquals(200, Helpers.toInt(result["status"]), "expected status 200")
    }

    if (!setup.live) {
      assertTrue(result["data"] is List<*>,
          "expected data to be an array, got " + result["data"])
      assertEquals(2, (result["data"] as List<Any?>).size, "expected 2 items")

      assertEquals(1, setup.calls.size, "expected 1 call")
`)

      if (listParams.length > 0) {
        Content(`      val call = setup.calls[0]
      val initMap = Helpers.toMapAny(call["init"])
      if (initMap != null) {
        assertEquals("GET", initMap["method"], "expected method GET")
      }
      val url = if (call["url"] is String) call["url"] as String else ""
`)
        for (let i = 0; i < listParams.length; i++) {
          Content(`      assertTrue(url.contains("direct0${i + 1}"),
          "expected url to contain direct0${i + 1}, got " + url)
`)
        }
      }

      Content(`    }
  }

`)
    }

    if (hasLoad && loadPoint) {
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
      for (liveKey in arrayOf<String>(${loadLiveIdKeys.map(k => `"${k}"`).join(', ')})) {
        Assumptions.assumeTrue(setup.idmap[liveKey] != null,
            "live test needs " + liveKey + " via *_ENTID env var (synthetic IDs only)")
      }
    }
`
        : ''

      Content(`  @Test
  fun directLoad${entity.Name}() {
    val setup = directSetup(jm("id", "direct01"))
    val mode = if (setup.live) "live" else "unit"
    val reason = RunnerSupport.skipReason("direct", "direct-load-${entity.name}", mode)
    Assumptions.assumeTrue(
      reason == null,
      if (reason == null || "" == reason) "skipped via sdk-test-control.json" else reason,
    )
${loadSkipBlock}    val client = setup.client

`)

      const needsQuery = loadParams.length > 0 || loadLiveQueryLines !== ''
      if (needsQuery) {
        Content(`    val params = linkedMapOf<String, Any?>()
    val query = linkedMapOf<String, Any?>()
`)

        Content(`    if (setup.live) {
`)

        if (loadLiveQueryLines) {
          Content(loadLiveQueryLines + '\n')
        }

        if (loadAllHaveExamples) {
          Content(loadExampleLines + '\n')
        } else if (hasList && loadParams.length > 0) {
          Content(`      val listParams = linkedMapOf<String, Any?>()
`)
          for (const p of listParams) {
            const key = p.name === 'id'
              ? entity.name + '01'
              : p.name.replace(/_id$/, '') + '01'
            Content(`      listParams["${p.name}"] = setup.idmap["${key}"]
`)
          }

          Content(`      val listResult = client.direct(jm(
          "path", "${listPath}",
          "method", "GET",
          "params", listParams))
      Assumptions.assumeTrue(listResult["ok"] == true,
          "list call not ok (likely synthetic IDs against live API): " + listResult)

      val listData = if (listResult["data"] is List<*>) listResult["data"] as List<Any?> else mutableListOf<Any?>()
      Assumptions.assumeTrue(listData.isNotEmpty(), "no entities to load in live mode")
      val firstEnt = Helpers.toMapAny(listData[0]) ?: linkedMapOf()
      params["id"] = firstEnt["id"]
`)
          for (const p of ancestorParams) {
            const key = p.name.replace(/_id$/, '') + '01'
            Content(`      params["${p.name}"] = setup.idmap["${key}"]
`)
          }
        }

        if (loadParams.length > 0) {
          Content(`    } else {
`)
          for (let i = 0; i < loadParams.length; i++) {
            Content(`      params["${loadParams[i].name}"] = "direct0${i + 1}"
`)
          }
        }
        Content(`    }
`)
      }

      if (needsQuery) {
        Content(`
    val result = client.direct(jm(
        "path", "${loadPath}",
        "method", "GET",
        "params", params,
        "query", query))
`)
      } else {
        Content(`
    val result = client.direct(jm(
        "path", "${loadPath}",
        "method", "GET",
        "params", linkedMapOf<String, Any?>()))
`)
      }

      Content(`    if (setup.live) {
      Assumptions.assumeTrue(result["ok"] == true,
          "load call not ok (likely synthetic IDs against live API): " + result)
      val status = Helpers.toInt(result["status"])
      Assumptions.assumeTrue(status in 200..299, "expected 2xx status, got " + result["status"])
    } else {
      assertEquals(true, result["ok"], "expected ok to be true")
      assertEquals(200, Helpers.toInt(result["status"]), "expected status 200")
      assertNotNull(result["data"], "expected data to be non-null")
    }

    if (!setup.live) {
      val dataMap = Helpers.toMapAny(result["data"])
      if (dataMap != null) {
        assertEquals("direct01", dataMap["id"], "expected data.id to be direct01")
      }

      assertEquals(1, setup.calls.size, "expected 1 call")
      val call = setup.calls[0]
      val initMap = Helpers.toMapAny(call["init"])
      if (initMap != null) {
        assertEquals("GET", initMap["method"], "expected method GET")
      }
      val url = if (call["url"] is String) call["url"] as String else ""
`)

      for (let i = 0; i < loadParams.length; i++) {
        Content(`      assertTrue(url.contains("direct0${i + 1}"),
          "expected url to contain direct0${i + 1}, got " + url)
`)
      }

      Content(`    }
  }

`)
    }

    Content(`  companion object {
    fun jm(vararg kv: Any?): MutableMap<String, Any?> {
      val out = linkedMapOf<String, Any?>()
      var i = 0
      while (i < kv.size - 1) {
        out[kv[i].toString()] = kv[i + 1]
        i += 2
      }
      return out
    }

    class DirectSetup {
      lateinit var client: ${SDK}
      var calls: MutableList<MutableMap<String, Any?>> = mutableListOf()
      var live: Boolean = false
      var idmap: MutableMap<String, Any?> = linkedMapOf()
    }

    fun directSetup(mockres: Any?): DirectSetup {
      RunnerSupport.loadEnvLocal()

      val calls = mutableListOf<MutableMap<String, Any?>>()

      val envm = linkedMapOf<String, Any?>()
      envm["${entidEnvVar}"] = linkedMapOf<String, Any?>()
      envm["${PROJECTNAME}_TEST_LIVE"] = "FALSE"
${authActive ? `      envm["${PROJECTNAME}_APIKEY"] = "NONE"\n` : ''}      val env = RunnerSupport.envOverride(envm)

      val live = "TRUE" == env["${PROJECTNAME}_TEST_LIVE"]

      val setup = DirectSetup()
      setup.calls = calls

      if (live) {
        val mergedOpts = linkedMapOf<String, Any?>()
${authActive ? `        mergedOpts["apikey"] = env["${PROJECTNAME}_APIKEY"]\n` : ''}        setup.client = ${SDK}(mergedOpts)
        setup.live = true

        var idmap: MutableMap<String, Any?> = linkedMapOf()
        val entidRaw = env["${entidEnvVar}"]
        if (entidRaw is String && entidRaw.startsWith("{")) {
          val parsed = Helpers.toMapAny(Json.parseOrNull(entidRaw))
          if (parsed != null) {
            idmap = parsed
          }
        } else if (entidRaw is MutableMap<*, *>) {
          idmap = entidRaw as MutableMap<String, Any?>
        }
        setup.idmap = idmap
        return setup
      }

      val mockdata: Any? = mockres ?: jm("id", "direct01")
      val mockFetch = BiFunction<String, MutableMap<String, Any?>, MutableMap<String, Any?>> { url, init ->
        calls.add(jm("url", url, "init", init))
        jm(
            "status", 200,
            "statusText", "OK",
            "headers", linkedMapOf<String, Any?>(),
            "json", Supplier<Any?> { mockdata })
      }

      setup.client = ${SDK}(jm(
          "base", "http://localhost:8080",
          "system", jm("fetch", mockFetch)))
      setup.live = false
      setup.idmap = linkedMapOf()
      return setup
    }
  }
}
`)
  })
})


export {
  TestDirect
}
