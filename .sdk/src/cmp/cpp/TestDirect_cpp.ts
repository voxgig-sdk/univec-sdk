
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


import { cppVarName } from './utility_cpp'


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


// Generates <entity>_direct_test.cpp: direct-call unit tests using a mock
// system.fetch (mirrors the rust/go TestDirect generator).
const TestDirect = cmp(function TestDirect(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const entity: ModelEntity = props.entity

  const ProjectName = model.const.Name

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

  const evar = cppVarName(entity.name)

  File({ name: entity.name + '_direct_test.cpp' }, () => {

    Content(`// Generated direct-call tests for the ${entity.name} entity (unit mode;
// a mock system.fetch records calls). Mirrors the rust/go TestDirect.

#include "runner_support.hpp"

using namespace sdk;
using namespace sdk::rs;

struct ${entity.Name}DirectSetup {
  std::shared_ptr<${ProjectName}SDK> client;
  Value calls;
  bool live = false;
};

static ${entity.Name}DirectSetup ${evar}_direct_setup(const Value& mockres) {
  Value calls = vlist();
  Value cshared = calls;

  vs::Injector mock_fetch = [cshared, mockres](vs::Injection&, const Value& args, const std::string&, const Value&) -> Value {
    Value url = vs::getelem(args, Value(int64_t(0)));
    Value init = vs::getelem(args, Value(int64_t(1)));
    cshared.as_list()->push_back(vmap({{"url", url}, {"init", init}}));
    Value data = is_nullish(mockres) ? vmap({{"id", Value("direct01")}}) : mockres;
    Value out = vmap();
    map_put(out, "status", Value(200));
    map_put(out, "statusText", Value("OK"));
    map_put(out, "headers", vmap());
    map_put(out, "json", json_thunk(data));
    return out;
  };

  Value opts = vmap({
    {"base", Value("http://localhost:8080")},
    {"system", vmap({{"fetch", Value(mock_fetch)}})}
  });
  auto client = std::make_shared<${ProjectName}SDK>(opts);

  ${entity.Name}DirectSetup s;
  s.client = client;
  s.calls = calls;
  s.live = false;
  return s;
}
`)

    // ---- list test ----
    if (hasList && listPoint) {
      Content(`
static void ${evar}_direct_list() {
  auto setup = ${evar}_direct_setup(vlist({
    vmap({{"id", Value("direct01")}}),
    vmap({{"id", Value("direct02")}})
  }));
  auto sk = is_control_skipped("direct", "direct-list-${entity.name}", "unit");
  if (sk.first) { std::cerr << "skip\\n"; return; }
  auto client = setup.client;

  Value params = vmap();
`)
      listParams.forEach((p: any, i: number) => {
        const placeholder = 'direct0' + (i + 1)
        Content(`  setp(params, "${p.name}", Value("${placeholder}"));
`)
      })
      Content(`
  Value result = client->direct(vmap({
    {"path", Value("${listPath}")},
    {"method", Value("GET")},
    {"params", params}
  }));

  ASSERT_EQ_VAL(getp(result, "ok"), Value(true), "expected ok true");
  ASSERT_EQ(Helpers::toInt(getp(result, "status")), 200, "expected status 200");
  Value data = getp(result, "data");
  ASSERT_TRUE(data.is_list(), "expected data to be an array");
  ASSERT_EQ((int)Struct::size(data), 2, "expected 2 items");
  ASSERT_EQ((int)setup.calls.as_list()->size(), 1, "expected 1 call");
`)
      if (listParams.length > 0) {
        Content(`  {
    Value call = (*setup.calls.as_list())[0];
    ASSERT_EQ_VAL(getp(getp(call, "init"), "method"), Value("GET"), "expected method GET");
    std::string url = as_str(getp(call, "url"));
`)
        for (let i = 0; i < listParams.length; i++) {
          Content(`    ASSERT_TRUE(url.find("direct0${i + 1}") != std::string::npos, "expected url to contain direct0${i + 1}");
`)
        }
        Content(`  }
`)
      }
      Content(`}
`)
    }

    // ---- load test ----
    if (hasLoad && loadPoint) {
      Content(`
static void ${evar}_direct_load() {
  auto setup = ${evar}_direct_setup(vmap({{"id", Value("direct01")}}));
  auto sk = is_control_skipped("direct", "direct-load-${entity.name}", "unit");
  if (sk.first) { std::cerr << "skip\\n"; return; }
  auto client = setup.client;

  Value params = vmap();
`)
      loadParams.forEach((p: any, i: number) => {
        const placeholder = 'direct0' + (i + 1)
        Content(`  setp(params, "${p.name}", Value("${placeholder}"));
`)
      })
      Content(`
  Value result = client->direct(vmap({
    {"path", Value("${loadPath}")},
    {"method", Value("GET")},
    {"params", params}
  }));

  ASSERT_EQ_VAL(getp(result, "ok"), Value(true), "expected ok true");
  ASSERT_EQ(Helpers::toInt(getp(result, "status")), 200, "expected status 200");
  ASSERT_TRUE(!getp(result, "data").is_undef(), "expected data to be non-nil");
  {
    Value data = getp(result, "data");
    if (data.is_map()) {
      ASSERT_EQ_VAL(getp(data, "id"), Value("direct01"), "expected data.id to be direct01");
    }
    ASSERT_EQ((int)setup.calls.as_list()->size(), 1, "expected 1 call");
    Value call = (*setup.calls.as_list())[0];
    ASSERT_EQ_VAL(getp(getp(call, "init"), "method"), Value("GET"), "expected method GET");
    std::string url = as_str(getp(call, "url"));
`)
      for (let i = 0; i < loadParams.length; i++) {
        Content(`    ASSERT_TRUE(url.find("direct0${i + 1}") != std::string::npos, "expected url to contain direct0${i + 1}");
`)
      }
      Content(`  }
}
`)
    }

    // main
    Content(`
int main() {
`)
    if (hasList && listPoint) Content(`  T_RUN(${evar}_direct_list);
`)
    if (hasLoad && loadPoint) Content(`  T_RUN(${evar}_direct_load);
`)
    Content(`  return sdktest::summary("${entity.name}_direct_test");
}
`)
  })
})


export {
  TestDirect
}
