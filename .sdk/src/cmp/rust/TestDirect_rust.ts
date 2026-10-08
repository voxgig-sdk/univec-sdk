
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


import { rustVarName } from './utility_rust'


// Blocked without the ids its request needs, rather than sent without them.
function liveKeysBlock(keys: string[], entidEnvVar: string): string {
  return 0 === keys.length ? '' : `    if setup.live {
        for live_key in [${keys.map((k) => JSON.stringify(k)).join(', ')}] {
            if getp(&setup.idmap, live_key).is_noval() {
                live_miss(LIVE_STRICT, &format!("Live test blocked: needs {} via ${entidEnvVar}", live_key));
                return;
            }
        }
    }
`
}


// Replace raw OpenAPI parameter names in path parts with model parameter
// names (twin of TestDirect_go's normalizePathParams).
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


const TestDirect = cmp(function TestDirect(props: any) {
  const ctx$ = props.ctx$
  const model: Model = ctx$.model

  const target = props.target
  const entity: ModelEntity = props.entity
  const rustcrate: string = props.rustcrate

  const PROJECTNAME = envName(model)

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n        ("${PROJECTNAME}_APIKEY", Value::str("")),`
    : ''
  const apikeyLiveField = authActive
    ? `("apikey", getp(&env, "${PROJECTNAME}_APIKEY"))`
    : ''

  const svars = serverVariables(model)
  const serverEnvEntry = svars
    .map((v: any) => `\n        ("${serverVarEnv(PROJECTNAME, v.name)}", Value::str(${JSON.stringify(v.dflt)})),`).join('')
  const serverLiveEntry = 0 === svars.length ? '' :
    `("server", jo(vec![${svars
      .map((v: any) => `("${v.name}", getp(&env, "${serverVarEnv(PROJECTNAME, v.name)}"))`).join(', ')}]))`
  const serverLiveField = '' === serverLiveEntry ? '' :
    ('' === apikeyLiveField ? serverLiveEntry : ', ' + serverLiveEntry)

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
  const loadPath = loadPoint ? normalizePathParams(pointParts(loadPoint), loadPoint?.g?.params || [], loadPoint?.r?.param) : ''
  const allLoadParams = loadPoint?.g?.params || []
  // Only path params that actually appear in the URL template drive the
  // direct-test path-param setup and URL-substitution asserts.
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

  // List point info.
  const listPoint = listOp?.points?.[0]
  const listPath = listPoint ? normalizePathParams(pointParts(listPoint), listPoint?.g?.params || [], listPoint?.r?.param) : ''
  const listParams = listPoint?.g?.params || []

  const entidEnvVar = `${PROJECTNAME}_TEST_${envToken(entity.name)}_ENTID`

  // The *_ENTID key a live test reads a parameter's value from.
  const liveKey = (param: any): string =>
    ('id' === param.n ? entity.name : param.n.replace(/_id$/, '')) + '01'

  const evar = rustVarName(entity.name)

  File({ name: entity.name + '_direct_test.' + target.ext }, () => {

    Content(`// Generated direct-call tests for the ${entity.name} entity (mirrors the
// go TestDirect generator; the live-mode path uses idmap-provided IDs).

#![allow(unused_variables, unused_imports, dead_code)]

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::*;

use ${rustcrate}::core::helpers::{getp, ja, jo, json_thunk, setp, to_int, to_map};
use ${rustcrate}::utility::voxgigstruct as vs;
use ${rustcrate}::{json_parse, Value, ${model.const.Name}SDK};

${liveStrictNote(liveStrict(model, target.name), '//')}
const LIVE_STRICT: bool = ${liveStrict(model, target.name)};

struct ${entity.Name}DirectSetup {
    client: Rc<${model.const.Name}SDK>,
    calls: Rc<RefCell<Vec<Value>>>,
    live: bool,
    idmap: Value,
}

fn ${evar}_direct_setup(mockres: Value) -> ${entity.Name}DirectSetup {
    load_env_local();

    let calls: Rc<RefCell<Vec<Value>>> = Rc::new(RefCell::new(Vec::new()));

    let env = env_override(jo(vec![
        ("${entidEnvVar}", Value::empty_map()),
        ("${PROJECTNAME}_TEST_LIVE", Value::str("FALSE")),${apikeyEnvEntry}${serverEnvEntry}
    ]));

    let live = getp(&env, "${PROJECTNAME}_TEST_LIVE") == Value::str("TRUE");

    if live {
        // live_client_options() FIRST, so the generated entries below win:
        // sdk-test-control.json's test.client.options adds to the live
        // client, it does not redirect it.
        let client = ${model.const.Name}SDK::new(to_map(&vs::merge(
            &ja(vec![
                live_client_options(),
                jo(vec![${apikeyLiveField}${serverLiveField}]),
            ]),
            None,
        )));
        let idmap = match to_map(&getp(&env, "${entidEnvVar}")) {
            Value::Map(m) => Value::Map(m),
            _ => Value::empty_map(),
        };
        return ${entity.Name}DirectSetup {
            client,
            calls,
            live: true,
            idmap,
        };
    }

    let c = calls.clone();
    let mock_fetch = Value::func(move |_inj, args, _r, _s| {
        let url = vs::get_elem(args, &Value::Num(0.0), Value::Noval);
        let init = vs::get_elem(args, &Value::Num(1.0), Value::Noval);
        c.borrow_mut().push(jo(vec![("url", url), ("init", init)]));
        let data = if mockres.is_noval() || mockres.is_null() {
            jo(vec![("id", Value::str("direct01"))])
        } else {
            mockres.clone()
        };
        jo(vec![
            ("status", Value::Num(200.0)),
            ("statusText", Value::str("OK")),
            ("headers", Value::empty_map()),
            ("json", json_thunk(data)),
        ])
    });

    let client = ${model.const.Name}SDK::new(jo(vec![
        ("base", Value::str("http://localhost:8080")),
        ("system", jo(vec![("fetch", mock_fetch)])),
    ]));

    ${entity.Name}DirectSetup {
        client,
        calls,
        live: false,
        idmap: Value::empty_map(),
    }
}
`)

    // ---- list test ----
    if (hasList && listPoint) {
      const listLiveParams = listParams.map((p: any) => ({ name: p.n, key: liveKey(p) }))

      Content(`
#[test]
fn ${evar}_direct_list() {
    let setup = ${evar}_direct_setup(ja(vec![
        jo(vec![("id", Value::str("direct01"))]),
        jo(vec![("id", Value::str("direct02"))]),
    ]));
    let mode = if setup.live { "live" } else { "unit" };
    let (skip, reason) = is_control_skipped("direct", "direct-list-${entity.name}", mode);
    if skip {
        eprintln!(
            "skip: {}",
            if reason.is_empty() {
                "skipped via sdk-test-control.json".to_string()
            } else {
                reason
            }
        );
        return;
    }
${liveKeysBlock(listLiveParams.map((lp: any) => lp.key), entidEnvVar)}    let client = setup.client.clone();

    let params = Value::empty_map();
`)
      listLiveParams.forEach((lp: any, i: number) => {
        Content(`    if setup.live {
        setp(&params, "${lp.name}", getp(&setup.idmap, "${lp.key}"));
    } else {
        setp(&params, "${lp.name}", Value::str("direct0${i + 1}"));
    }
`)
      })

      Content(`
    let result = match client.direct(jo(vec![
        ("path", Value::str("${listPath}")),
        ("method", Value::str("GET")),
        ("params", params.clone()),
    ])) {
        Ok(result) => result,
        Err(err) if setup.live => {
            live_miss(LIVE_STRICT, &format!("Live list failed: {}", err));
            return;
        }
        Err(err) => panic!("direct failed: {}", err),
    };

    if setup.live {
        if !live_ok(&result) {
            live_miss(LIVE_STRICT, &format!("Live list failed: {}", live_describe(&result)));
            return;
        }
        if live_list(&getp(&result, "data")).is_none() {
            live_miss(LIVE_STRICT, &format!("Live list returned no list: {}", live_describe(&result)));
            return;
        }
    } else {
        assert_eq!(getp(&result, "ok"), Value::Bool(true), "expected ok true");
        assert_eq!(to_int(&getp(&result, "status")), 200, "expected status 200");

        let data = getp(&result, "data");
        assert!(
            matches!(data, Value::List(_)),
            "expected data to be an array"
        );
        assert_eq!(vs::size(&data), 2, "expected 2 items");

        assert_eq!(setup.calls.borrow().len(), 1, "expected 1 call");
`)

      if (listParams.length > 0) {
        Content(`
        let call = setup.calls.borrow()[0].clone();
        assert_eq!(
            getp(&getp(&call, "init"), "method"),
            Value::str("GET"),
            "expected method GET"
        );
        let url = match getp(&call, "url") {
            Value::Str(u) => u,
            _ => String::new(),
        };
`)
        for (let i = 0; i < listParams.length; i++) {
          Content(`        assert!(
            url.contains("direct0${i + 1}"),
            "expected url to contain direct0${i + 1}, got {}",
            url
        );
`)
        }
      }

      Content(`    }
}
`)
    }

    // ---- load test ----
    if (hasLoad && loadPoint) {
      const examples = 0 < loadParams.length &&
        loadParams.every((p: any) => undefined !== p.ex && null !== p.ex)
      const discover = !examples && hasList && 0 < loadParams.length
      const idParam = loadParams.find((p: any) => 'id' === p.n)?.n ?? loadParams[0]?.n ?? 'id'
      const loadLiveIdKeys: string[] = examples ? [] :
        discover ? listParams.map(liveKey).concat(loadParams.filter((p: any) => idParam !== p.n).map(liveKey)) :
          loadParams.map(liveKey)

      Content(`
#[test]
fn ${evar}_direct_load() {
    let setup = ${evar}_direct_setup(jo(vec![("id", Value::str("direct01"))]));
    let mode = if setup.live { "live" } else { "unit" };
    let (skip, reason) = is_control_skipped("direct", "direct-load-${entity.name}", mode);
    if skip {
        eprintln!(
            "skip: {}",
            if reason.is_empty() {
                "skipped via sdk-test-control.json".to_string()
            } else {
                reason
            }
        );
        return;
    }
${liveKeysBlock([...new Set(loadLiveIdKeys)], entidEnvVar)}    let client = setup.client.clone();

    let params = Value::empty_map();
    if setup.live {
`)
      if (examples) {
        for (const p of loadParams) {
          Content(`        setp(&params, "${p.n}", json_parse(r##"${JSON.stringify(p.ex)}"##).unwrap_or(Value::Noval));
`)
        }
      }
      else if (discover) {
        Content(`        let list_result = match client.direct(jo(vec![
            ("path", Value::str("${listPath}")),
            ("method", Value::str("GET")),
            ("params", jo(vec![${listParams.map((p: any) => `("${p.n}", getp(&setup.idmap, "${liveKey(p)}"))`).join(', ')}])),
        ])) {
            Ok(list_result) => list_result,
            Err(err) => {
                live_miss(LIVE_STRICT, &format!("Live list discovery failed: {}", err));
                return;
            }
        };
        if !live_ok(&list_result) {
            live_miss(LIVE_STRICT, &format!("Live list discovery failed: {}", live_describe(&list_result)));
            return;
        }
        let records = match live_list(&getp(&list_result, "data")) {
            Some(records) => records,
            None => {
                live_miss(LIVE_STRICT, &format!("Live list discovery returned no list: {}", live_describe(&list_result)));
                return;
            }
        };
        let first = vs::get_elem(&records, &Value::Num(0.0), Value::Noval);
        if first.is_noval() {
            live_empty("The account has no ${entity.name} record to load");
            return;
        }
        let mut found = getp(&first, "${idParam}");
        if found.is_noval() {
            found = getp(&first, "id");
        }
        if found.is_noval() {
            live_miss(LIVE_STRICT, "Live load blocked: discovery returned no usable identity");
            return;
        }
        setp(&params, "${idParam}", found);
`)
        for (const p of loadParams.filter((p: any) => idParam !== p.n)) {
          Content(`        setp(&params, "${p.n}", getp(&setup.idmap, "${liveKey(p)}"));
`)
        }
      }
      else {
        for (const p of loadParams) {
          Content(`        setp(&params, "${p.n}", getp(&setup.idmap, "${liveKey(p)}"));
`)
        }
      }
      Content(`    } else {
`)
      loadParams.forEach((p: any, i: number) => {
        Content(`        setp(&params, "${p.n}", Value::str("direct0${i + 1}"));
`)
      })
      Content(`    }

    let result = match client.direct(jo(vec![
        ("path", Value::str("${loadPath}")),
        ("method", Value::str("GET")),
        ("params", params.clone()),
    ])) {
        Ok(result) => result,
        Err(err) if setup.live => {
            live_miss(LIVE_STRICT, &format!("Live load failed: {}", err));
            return;
        }
        Err(err) => panic!("direct failed: {}", err),
    };

    if setup.live {
        if !live_ok(&result) {
            live_miss(LIVE_STRICT, &format!("Live load failed: {}", live_describe(&result)));
            return;
        }
        if getp(&result, "data").is_noval() {
            live_miss(LIVE_STRICT, &format!("Live load returned no data: {}", live_describe(&result)));
            return;
        }
    } else {
        assert_eq!(getp(&result, "ok"), Value::Bool(true), "expected ok true");
        assert_eq!(to_int(&getp(&result, "status")), 200, "expected status 200");
        assert!(
            !getp(&result, "data").is_noval(),
            "expected data to be non-nil"
        );

        let data = getp(&result, "data");
        if let Value::Map(_) = data {
            assert_eq!(
                getp(&data, "id"),
                Value::str("direct01"),
                "expected data.id to be direct01"
            );
        }

        assert_eq!(setup.calls.borrow().len(), 1, "expected 1 call");
        let call = setup.calls.borrow()[0].clone();
        assert_eq!(
            getp(&getp(&call, "init"), "method"),
            Value::str("GET"),
            "expected method GET"
        );
        let url = match getp(&call, "url") {
            Value::Str(u) => u,
            _ => String::new(),
        };
`)

      for (let i = 0; i < loadParams.length; i++) {
        Content(`        assert!(
            url.contains("direct0${i + 1}"),
            "expected url to contain direct0${i + 1}, got {}",
            url
        );
`)
      }

      Content(`    }
}
`)
    }
  })
})


export {
  TestDirect
}
