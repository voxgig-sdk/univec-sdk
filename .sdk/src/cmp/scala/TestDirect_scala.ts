
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
} from '@voxgig/sdkgen'


// Replace raw OpenAPI parameter names in path parts with model parameter
// names (twin of TestDirect_java's normalizePathParams). Path parts may have
// {subBreed} while model params use sub_breed; a rename mapping (closureId ->
// id) means the part uses {id} while the param keeps its original name.
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
  const scalapackage: string = props.scalapackage

  const SDK = model.const.Name + 'SDK'
  const EntityName = nom(entity, 'Name')
  const ENTLOWER = entity.name

  const opnames = Object.keys(entity.op || {})
  const hasLoad = opnames.includes('load')
  const hasList = opnames.includes('list')

  if (!hasLoad && !hasList) {
    return
  }

  const loadOp = (entity.op as any)?.load
  const listOp = (entity.op as any)?.list

  // Load point info.
  const loadPoint = loadOp?.points?.[0]
  const loadPath = loadPoint
    ? normalizePathParams(loadPoint.parts || [], loadPoint?.args?.params || [], loadPoint?.rename?.param)
    : ''
  const allLoadParams = loadPoint?.args?.params || []
  // Only path params that actually appear in the URL template drive the
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

  // List point info.
  const listPoint = listOp?.points?.[0]
  const listPath = listPoint
    ? normalizePathParams(listPoint.parts || [], listPoint?.args?.params || [], listPoint?.rename?.param)
    : ''
  const listParams = listPoint?.args?.params || []

  File({ name: EntityName + 'DirectTest.' + target.ext }, () => {

    Content(`// Generated direct-call tests for the ${ENTLOWER} entity (mirrors the java
// TestDirect generator). A dependency-free scala-cli test object driven by
// SdkEntityTestMain: an offline mock transport records each call and the
// asserts confirm path-param substitution and the response shape.

import java.util.{ArrayList, LinkedHashMap, List => JList, Map => JMap}
import java.util.function.{BiFunction, Supplier}

import ${scalapackage}.core.{Helpers, SdkEntity, ${SDK}}

object ${EntityName}DirectTest {

  private class DirectSetup(val client: ${SDK}, val calls: JList[JMap[String, Object]])

  private def directSetup(mockres: Object): DirectSetup = {
    val calls = new ArrayList[JMap[String, Object]]()
    val mockdata: Object = if (mockres != null) mockres else SdkTestSupport.om("id" -> "direct01")
    val mockFetch: BiFunction[String, JMap[String, Object], Object] =
      (url, init) => {
        calls.add(SdkTestSupport.om("url" -> url, "init" -> init))
        val js: Supplier[Object] = () => mockdata
        SdkTestSupport.om(
          "status" -> SdkTestSupport.I(200),
          "statusText" -> "OK",
          "headers" -> new LinkedHashMap[String, Object](),
          "json" -> js)
      }
    val client = new ${SDK}(SdkTestSupport.om(
      "base" -> "http://localhost:8080",
      "system" -> SdkTestSupport.om("fetch" -> mockFetch)))
    new DirectSetup(client, calls)
  }

  def run(rep: SdkTestReport): Unit = {
`)

    // ---- list test ----
    if (hasList && listPoint) {
      Content(`    rep.scope("direct-list-${ENTLOWER}") {
      val setup = directSetup(SdkTestSupport.jl(
          SdkTestSupport.om("id" -> "direct01"),
          SdkTestSupport.om("id" -> "direct02")))
      val client = setup.client

      val params = new LinkedHashMap[String, Object]()
`)
      listParams.forEach((p: any, i: number) => {
        Content(`      params.put("${p.name}", "direct0${i + 1}")
`)
      })
      Content(`      val result = client.direct(SdkTestSupport.om(
          "path" -> "${listPath}",
          "method" -> "GET",
          "params" -> params))

      rep.eq("direct-list-${ENTLOWER}.ok", java.lang.Boolean.TRUE, result.get("ok"))
      rep.eqI("direct-list-${ENTLOWER}.status", 200, Helpers.toInt(result.get("status")))
      rep.check("direct-list-${ENTLOWER}.islist", result.get("data").isInstanceOf[JList[?]], "expected data to be an array, got " + result.get("data"))
      val listData = result.get("data").asInstanceOf[JList[Object]]
      rep.eqI("direct-list-${ENTLOWER}.size", 2, listData.size())
      rep.eqI("direct-list-${ENTLOWER}.calls", 1, setup.calls.size())
`)
      if (listParams.length > 0) {
        Content(`      val url = setup.calls.get(0).get("url") match { case s: String => s; case _ => "" }
`)
        for (let i = 0; i < listParams.length; i++) {
          Content(`      rep.check("direct-list-${ENTLOWER}.url${i + 1}", url.contains("direct0${i + 1}"), "expected url to contain direct0${i + 1}, got " + url)
`)
        }
      }
      Content(`    }

`)
    }

    // ---- load test ----
    if (hasLoad && loadPoint) {
      Content(`    rep.scope("direct-load-${ENTLOWER}") {
      val setup = directSetup(SdkTestSupport.om("id" -> "direct01"))
      val client = setup.client

      val params = new LinkedHashMap[String, Object]()
`)
      loadParams.forEach((p: any, i: number) => {
        Content(`      params.put("${p.name}", "direct0${i + 1}")
`)
      })
      Content(`      val result = client.direct(SdkTestSupport.om(
          "path" -> "${loadPath}",
          "method" -> "GET",
          "params" -> params))

      rep.eq("direct-load-${ENTLOWER}.ok", java.lang.Boolean.TRUE, result.get("ok"))
      rep.eqI("direct-load-${ENTLOWER}.status", 200, Helpers.toInt(result.get("status")))
      rep.check("direct-load-${ENTLOWER}.data", result.get("data") != null, "expected data to be non-null")
      val dataMap = Helpers.toMapAny(result.get("data"))
      if (dataMap != null) rep.eq("direct-load-${ENTLOWER}.dataId", "direct01", dataMap.get("id"))
      rep.eqI("direct-load-${ENTLOWER}.calls", 1, setup.calls.size())
`)
      if (loadParams.length > 0) {
        Content(`      val url = setup.calls.get(0).get("url") match { case s: String => s; case _ => "" }
`)
        for (let i = 0; i < loadParams.length; i++) {
          Content(`      rep.check("direct-load-${ENTLOWER}.url${i + 1}", url.contains("direct0${i + 1}"), "expected url to contain direct0${i + 1}, got " + url)
`)
        }
      }
      Content(`    }
`)
    }

    Content(`  }
}
`)
  })
})


export {
  TestDirect
}
