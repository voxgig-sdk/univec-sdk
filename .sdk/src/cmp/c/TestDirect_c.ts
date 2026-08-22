
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


import { cIdent, cVarName } from './utility_c'


// Replace raw OpenAPI parameter names in path parts with model parameter
// names (twin of TestDirect_rust's normalizePathParams).
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

  const entity: ModelEntity = props.entity

  const ident = cIdent(model)
  const evar = cVarName(entity.name)
  const Name = model.const.Name

  const opnames = Object.keys(entity.op || {})
  const hasLoad = opnames.includes('load')
  const hasList = opnames.includes('list')
  if (!hasLoad && !hasList) {
    return
  }

  const loadOp = (entity.op as any)?.load
  const listOp = (entity.op as any)?.list

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

  File({ name: entity.name + '_direct_test.c' }, () => {

    Content(`// Generated direct-call test for the ${entity.name} entity (mirrors the
// rust TestDirect generator; unit mode uses a mock system.fetch transport).

#include "ctest.h"

#include <stdlib.h>
#include <string.h>

static int CALLS = 0;
static char LAST_URL[1024];

// Mock transport: records the call, returns 200 + the ud response as json.
static voxgig_value* ${evar}_mock(void* ud, voxgig_value* args) {
  CALLS++;
  voxgig_value* url = voxgig_getelem(args, v_int(0), NULL);
  if (voxgig_is_string(url)) {
    snprintf(LAST_URL, sizeof(LAST_URL), "%s", voxgig_as_string(url));
  }
  voxgig_value* data = (voxgig_value*)ud;
  return cmap(4,
    "status", v_num(200),
    "statusText", v_str("OK"),
    "headers", v_map(),
    "json", json_thunk(data));
}

static ${Name}SDK* ${evar}_direct_setup(voxgig_value* mockres) {
  voxgig_value* opts = cmap(2,
    "base", v_str("http://localhost:8080"),
    "system", cmap(1, "fetch", vfn(${evar}_mock, mockres)));
  return ${ident}_sdk_new(opts);
}

int main(void) {
`)

    // ---- list test ----
    if (hasList && listPoint) {
      Content(`
  // LIST
  {
    CALLS = 0;
    voxgig_value* mockres = clist(2,
      cmap(1, "id", v_str("direct01")),
      cmap(1, "id", v_str("direct02")));
    ${Name}SDK* sdk = ${evar}_direct_setup(mockres);
    voxgig_value* params = v_map();
`)
      for (let i = 0; i < listParams.length; i++) {
        const placeholder = 'direct0' + (i + 1)
        Content(`    setp(params, "${listParams[i].name}", v_str("${placeholder}"));
`)
      }
      Content(`    PNError* err = NULL;
    voxgig_value* result = sdk_direct(sdk, cmap(3,
      "path", v_str("${listPath}"),
      "method", v_str("GET"),
      "params", params), &err);
    CHECK(err == NULL, "list: no error");
    voxgig_value* okv = getp(result, "ok");
    CHECK(voxgig_is_bool(okv) && voxgig_as_bool(okv), "list: ok true");
    CHECK_INT_EQ(to_int(getp(result, "status")), 200, "list: status 200");
    voxgig_value* data = getp(result, "data");
    CHECK(voxgig_is_list(data), "list: data is array");
    CHECK_INT_EQ(voxgig_size(data), 2, "list: 2 items");
    CHECK_INT_EQ(CALLS, 1, "list: one call");
`)
      for (let i = 0; i < listParams.length; i++) {
        Content(`    CHECK(strstr(LAST_URL, "direct0${i + 1}") != NULL, "list: url has direct0${i + 1}");
`)
      }
      Content(`  }
`)
    }

    // ---- load test ----
    if (hasLoad && loadPoint) {
      Content(`
  // LOAD
  {
    CALLS = 0;
    voxgig_value* mockres = cmap(1, "id", v_str("direct01"));
    ${Name}SDK* sdk = ${evar}_direct_setup(mockres);
    voxgig_value* params = v_map();
`)
      for (let i = 0; i < loadParams.length; i++) {
        const placeholder = 'direct0' + (i + 1)
        Content(`    setp(params, "${loadParams[i].name}", v_str("${placeholder}"));
`)
      }
      Content(`    PNError* err = NULL;
    voxgig_value* result = sdk_direct(sdk, cmap(3,
      "path", v_str("${loadPath}"),
      "method", v_str("GET"),
      "params", params), &err);
    CHECK(err == NULL, "load: no error");
    voxgig_value* okv = getp(result, "ok");
    CHECK(voxgig_is_bool(okv) && voxgig_as_bool(okv), "load: ok true");
    CHECK_INT_EQ(to_int(getp(result, "status")), 200, "load: status 200");
    voxgig_value* data = getp(result, "data");
    CHECK(!v_is_noval(data), "load: data present");
    if (voxgig_is_map(data)) {
      CHECK_STR_EQ(get_str(data, "id"), "direct01", "load: data.id");
    }
    CHECK_INT_EQ(CALLS, 1, "load: one call");
`)
      for (let i = 0; i < loadParams.length; i++) {
        Content(`    CHECK(strstr(LAST_URL, "direct0${i + 1}") != NULL, "load: url has direct0${i + 1}");
`)
      }
      Content(`  }
`)
    }

    Content(`
  TEST_SUMMARY("${ident}_${evar}_direct");
}
`)
  })
})


export {
  TestDirect
}
