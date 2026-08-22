
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


import { rustVarName } from './utility_rust'


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
  const rustcrate: string = props.rustcrate

  const PROJECTNAME = envName(model)

  const authActive = isAuthActive(model)
  const apikeyEnvEntry = authActive
    ? `\n        ("${PROJECTNAME}_APIKEY", Value::str("NONE")),`
    : ''
  const apikeyLiveField = authActive
    ? `("apikey", getp(&env, "${PROJECTNAME}_APIKEY"))`
    : ''

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
  const loadPath = loadPoint ? normalizePathParams(loadPoint.parts || [], loadPoint?.args?.params || [], loadPoint?.rename?.param) : ''
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
  const listPath = listPoint ? normalizePathParams(listPoint.parts || [], listPoint?.args?.params || [], listPoint?.rename?.param) : ''
  const listParams = listPoint?.args?.params || []

  const entidEnvVar = `${PROJECTNAME}_TEST_${envToken(entity.name)}_ENTID`

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
use ${rustcrate}::{Value, ${model.const.Name}SDK};

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
        ("${PROJECTNAME}_TEST_LIVE", Value::str("FALSE")),${apikeyEnvEntry}
    ]));

    let live = getp(&env, "${PROJECTNAME}_TEST_LIVE") == Value::str("TRUE");

    if live {
        let client = ${model.const.Name}SDK::new(jo(vec![${apikeyLiveField}]));
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
      // Live params: idmap keys per param.
      const listLiveParams = listParams.map((p: any) => {
        const key = p.name === 'id'
          ? entity.name + '01'
          : p.name.replace(/_id$/, '') + '01'
        return { name: p.name, key }
      })

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
`)

      if (listLiveParams.length > 0) {
        Content(`    if setup.live {
        for live_key in [${listLiveParams.map((lp: any) => `"${lp.key}"`).join(', ')}] {
            if getp(&setup.idmap, live_key).is_noval() {
                eprintln!("skip: live test needs {} via *_ENTID env var (synthetic IDs only)", live_key);
                return;
            }
        }
    }
`)
      }

      Content(`    let client = setup.client.clone();

    let params = Value::empty_map();
`)
      listLiveParams.forEach((lp: any, i: number) => {
        const placeholder = 'direct0' + (i + 1)
        Content(`    if setup.live {
        setp(&params, "${lp.name}", getp(&setup.idmap, "${lp.key}"));
    } else {
        setp(&params, "${lp.name}", Value::str("${placeholder}"));
    }
`)
      })

      Content(`
    let result = client
        .direct(jo(vec![
            ("path", Value::str("${listPath}")),
            ("method", Value::str("GET")),
            ("params", params.clone()),
        ]))
        .expect("direct failed");

    if setup.live {
        // Live mode is lenient: synthetic IDs frequently 4xx and the
        // list-response shape varies wildly across public APIs.
        if getp(&result, "ok") != Value::Bool(true) {
            eprintln!("skip: list call not ok (likely synthetic IDs against live API)");
            return;
        }
        let status = to_int(&getp(&result, "status"));
        if !(200..300).contains(&status) {
            eprintln!("skip: expected 2xx status, got {}", status);
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
      // idmap keys consumed by load in live mode.
      const loadLiveParams = loadParams.map((p: any) => {
        const key = p.name === 'id'
          ? entity.name + '01'
          : p.name.replace(/_id$/, '') + '01'
        return { name: p.name, key }
      })

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
`)

      if (loadLiveParams.length > 0) {
        Content(`    if setup.live {
        for live_key in [${loadLiveParams.map((lp: any) => `"${lp.key}"`).join(', ')}] {
            if getp(&setup.idmap, live_key).is_noval() {
                eprintln!("skip: live test needs {} via *_ENTID env var (synthetic IDs only)", live_key);
                return;
            }
        }
    }
`)
      }

      Content(`    let client = setup.client.clone();

    let params = Value::empty_map();
`)

      loadLiveParams.forEach((lp: any, i: number) => {
        const placeholder = 'direct0' + (i + 1)
        Content(`    if setup.live {
        setp(&params, "${lp.name}", getp(&setup.idmap, "${lp.key}"));
    } else {
        setp(&params, "${lp.name}", Value::str("${placeholder}"));
    }
`)
      })

      Content(`
    let result = client
        .direct(jo(vec![
            ("path", Value::str("${loadPath}")),
            ("method", Value::str("GET")),
            ("params", params.clone()),
        ]))
        .expect("direct failed");

    if setup.live {
        // Live mode is lenient: synthetic IDs frequently 4xx.
        if getp(&result, "ok") != Value::Bool(true) {
            eprintln!("skip: load call not ok (likely synthetic IDs against live API)");
            return;
        }
        let status = to_int(&getp(&result, "status"));
        if !(200..300).contains(&status) {
            eprintln!("skip: expected 2xx status, got {}", status);
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
