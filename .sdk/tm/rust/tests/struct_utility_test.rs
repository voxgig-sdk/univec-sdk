// Struct utility tests — run the shared `struct` corpus subtree from
// ../.sdk/test/test.json against the vendored voxgig struct port
// (mirrors tm/go/test/struct_utility_test.go).

mod struct_runner;

use std::cell::RefCell;
use std::rc::Rc;

use struct_runner::*;

use RUSTCRATE::utility::voxgigstruct::ordered_map::OrderedMap;
use RUSTCRATE::utility::voxgigstruct::value::Value;
use RUSTCRATE::utility::voxgigstruct::*;


#[test]
fn struct_utility() {
    let spec = test_json();
    let s = vget(&spec, "struct");
    let mut run = Run::new();

    macro_rules! set {
        ($cat:expr, $name:expr) => {
            vget_path(&s, &[$cat, $name])
        };
    }

    // -------- minor --------------------------------------------------
    run.run_set(&set!("minor", "isnode"), true, "minor-isnode", |v| {
        b(is_node(&v))
    });
    run.run_set(&set!("minor", "ismap"), true, "minor-ismap", |v| {
        b(is_map(&v))
    });
    run.run_set(&set!("minor", "islist"), true, "minor-islist", |v| {
        b(is_list(&v))
    });
    run.run_set(&set!("minor", "iskey"), false, "minor-iskey", |v| {
        b(is_key(&v))
    });
    run.run_set(&set!("minor", "strkey"), false, "minor-strkey", |v| {
        Value::str(str_key(v))
    });
    run.run_set(&set!("minor", "isempty"), false, "minor-isempty", |v| {
        b(is_empty(&v))
    });
    run.run_set(&set!("minor", "isfunc"), true, "minor-isfunc", |v| {
        b(is_func(&v))
    });
    run.run_set(&set!("minor", "clone"), false, "minor-clone", |v| clone(&v));
    run.run_set(&set!("minor", "filter"), true, "minor-filter", |vin| {
        let val = vget(&vin, "val");
        let check = as_str_opt(&vget(&vin, "check")).unwrap_or_default();
        filter(&val, move |n| match check.as_str() {
            "gt3" => matches!(&n.1, Value::Num(x) if *x > 3.0),
            "lt3" => matches!(&n.1, Value::Num(x) if *x < 3.0),
            _ => false,
        })
    });
    run.run_set(&set!("minor", "flatten"), true, "minor-flatten", |vin| {
        flatten(&vget(&vin, "val"), as_i64_opt(&vget(&vin, "depth")))
    });
    run.run_set(&set!("minor", "escre"), true, "minor-escre", |v| {
        Value::str(esc_re(&v))
    });
    run.run_set(&set!("minor", "escurl"), true, "minor-escurl", |v| {
        Value::str(esc_url(&v))
    });
    run.run_set(
        &set!("minor", "stringify"),
        true,
        "minor-stringify",
        |vin| {
            let mut val = vget(&vin, "val");
            if val == Value::str(NULLMARK) {
                val = Value::str("null");
            }
            Value::str(stringify(&val, as_i64_opt(&vget(&vin, "max")), false))
        },
    );
    run.run_set(&set!("minor", "jsonify"), false, "minor-jsonify", |vin| {
        let flags_v = vget(&vin, "flags");
        let flags = if flags_v.is_noval() {
            None
        } else {
            let indent = as_i64_opt(&vget(&flags_v, "indent")).unwrap_or(2).max(0) as usize;
            let offset = as_i64_opt(&vget(&flags_v, "offset")).unwrap_or(0).max(0) as usize;
            Some(JsonFlags { indent, offset })
        };
        Value::str(jsonify(&vget(&vin, "val"), flags.as_ref()))
    });
    run.run_set(&set!("minor", "pathify"), true, "minor-pathify", |vin| {
        let pathv = vget(&vin, "path");
        let path = if pathv == Value::str(NULLMARK) {
            Value::Noval
        } else {
            pathv.clone()
        };
        let mut ps = pathify(&path, as_i64_opt(&vget(&vin, "from")), None);
        ps = ps.replace("__NULL__.", "");
        if pathv == Value::str(NULLMARK) {
            ps = ps.replace('>', ":null>");
        }
        Value::str(ps)
    });
    run.run_set(&set!("minor", "items"), true, "minor-items", |v| items(&v));
    run.run_set(&set!("minor", "getelem"), false, "minor-getelem", |vin| {
        let alt = vget(&vin, "alt");
        get_elem(&vget(&vin, "val"), &vget(&vin, "key"), alt)
    });
    run.run_set(&set!("minor", "getprop"), false, "minor-getprop", |vin| {
        let alt = vget(&vin, "alt");
        get_prop(&vget(&vin, "val"), &vget(&vin, "key"), alt)
    });
    run.run_set(&set!("minor", "setprop"), true, "minor-setprop", |vin| {
        set_prop(vget(&vin, "parent"), &vget(&vin, "key"), vget(&vin, "val"))
    });
    run.run_set(&set!("minor", "delprop"), true, "minor-delprop", |vin| {
        del_prop(vget(&vin, "parent"), &vget(&vin, "key"))
    });
    run.run_set(&set!("minor", "haskey"), false, "minor-haskey", |vin| {
        b(has_key(&vget(&vin, "src"), &vget(&vin, "key")))
    });
    run.run_set(&set!("minor", "keysof"), true, "minor-keysof", |v| {
        keys_of(&v)
    });
    run.run_set(&set!("minor", "join"), false, "minor-join", |vin| {
        let val = vget(&vin, "val");
        let sep = as_str_opt(&vget(&vin, "sep"));
        let url = matches!(vget(&vin, "url"), Value::Bool(true));
        Value::str(join(&val, sep.as_deref(), url))
    });
    run.run_set(&set!("minor", "typename"), true, "minor-typename", |v| {
        Value::str(type_name(v.as_num().unwrap_or(0.0) as i64))
    });
    run.run_set(&set!("minor", "typify"), false, "minor-typify", |v| {
        Value::Num(typify(&v) as f64)
    });
    run.run_set(&set!("minor", "size"), false, "minor-size", |v| {
        Value::Num(size(&v) as f64)
    });
    run.run_set(&set!("minor", "slice"), false, "minor-slice", |vin| {
        slice(
            vget(&vin, "val"),
            as_i64_opt(&vget(&vin, "start")),
            as_i64_opt(&vget(&vin, "end")),
            false,
        )
    });
    run.run_set(&set!("minor", "pad"), false, "minor-pad", |vin| {
        Value::str(pad(
            vget(&vin, "val"),
            as_i64_opt(&vget(&vin, "pad")),
            as_str_opt(&vget(&vin, "char")),
        ))
    });
    run.run_set(&set!("minor", "setpath"), false, "minor-setpath", |vin| {
        set_path(
            &vget(&vin, "store"),
            &vget(&vin, "path"),
            vget(&vin, "val"),
            None,
        )
    });

    // -------- sentinels (Group A null-unification; UNDEF_SPEC.md) ----
    // null_flag is false so a literal JSON null survives into the subject
    // (these tests exercise getprop/getelem/haskey/isempty/isnode/stringify
    // against stored null directly; mirrors perl/t/struct.t sentinels block).
    run.run_set(
        &set!("sentinels", "getprop_unify"),
        false,
        "sentinels-getprop_unify",
        |vin| {
            let alt = vget(&vin, "alt");
            get_prop(&vget(&vin, "val"), &vget(&vin, "key"), alt)
        },
    );
    run.run_set(
        &set!("sentinels", "getelem_absent"),
        false,
        "sentinels-getelem_absent",
        |vin| {
            let alt = vget(&vin, "alt");
            get_elem(&vget(&vin, "val"), &vget(&vin, "key"), alt)
        },
    );
    run.run_set(
        &set!("sentinels", "haskey_unify"),
        false,
        "sentinels-haskey_unify",
        |vin| b(has_key(&vget(&vin, "val"), &vget(&vin, "key"))),
    );
    run.run_set(
        &set!("sentinels", "isempty_unify"),
        false,
        "sentinels-isempty_unify",
        |v| b(is_empty(&v)),
    );
    run.run_set(
        &set!("sentinels", "isnode_unify"),
        false,
        "sentinels-isnode_unify",
        |v| b(is_node(&v)),
    );
    run.run_set(
        &set!("sentinels", "stringify_null"),
        false,
        "sentinels-stringify_null",
        |v| Value::str(stringify(&v, None, false)),
    );

    // -------- walk ---------------------------------------------------
    run.run_set(&set!("walk", "basic"), true, "walk-basic", |vin| {
        let mut walkpath = |_k: &Value, val: &Value, _p: &Value, path: &[String]| -> Value {
            match val {
                Value::Str(sv) => Value::str(format!("{}~{}", sv, path.join("."))),
                _ => val.clone(),
            }
        };
        walk(vin, Some(&mut walkpath), None, None)
    });
    // walk.log — three runs (after-only / before-only / both) of a logging callback.
    {
        let log_spec = vget_path(&s, &["walk", "log"]);
        let input = clone(&vget(&log_spec, "in"));
        let want = vget(&log_spec, "out");
        let mk_log = |inp: &Value, before: bool, after: bool| -> Value {
            let lines = Rc::new(RefCell::new(Vec::<Value>::new()));
            let lc = lines.clone();
            let mut cb = move |k: &Value, v: &Value, p: &Value, path: &[String]| -> Value {
                lc.borrow_mut().push(Value::str(format!(
                    "k={}, v={}, p={}, t={}",
                    stringify(k, None, false),
                    stringify(v, None, false),
                    stringify(p, None, false),
                    pathify(
                        &Value::list(path.iter().cloned().map(Value::Str).collect()),
                        None,
                        None
                    ),
                )));
                v.clone()
            };
            let mut cb2 = {
                let lc = lines.clone();
                move |k: &Value, v: &Value, p: &Value, path: &[String]| -> Value {
                    lc.borrow_mut().push(Value::str(format!(
                        "k={}, v={}, p={}, t={}",
                        stringify(k, None, false),
                        stringify(v, None, false),
                        stringify(p, None, false),
                        pathify(
                            &Value::list(path.iter().cloned().map(Value::Str).collect()),
                            None,
                            None
                        ),
                    )));
                    v.clone()
                }
            };
            let _ = walk(
                clone(inp),
                if before { Some(&mut cb) } else { None },
                if after { Some(&mut cb2) } else { None },
                None,
            );
            let out = Value::list(lines.borrow().clone());
            out
        };
        for (label, b, a) in [
            ("after", false, true),
            ("before", true, false),
            ("both", true, true),
        ] {
            let got = mk_log(&input, b, a);
            let exp = vget(&want, label);
            if got == exp {
                run.passed += 1;
            } else {
                run.failures.push(format!(
                    "walk-log/{label}: got {}, want {}",
                    stringify(&got, Some(220), false),
                    stringify(&exp, Some(220), false)
                ));
            }
        }
    }
    // walk.depth — reconstruct `src` truncated at `maxdepth`.
    run.run_set(&set!("walk", "depth"), false, "walk-depth", |vin| {
        let top: Rc<RefCell<Value>> = Rc::new(RefCell::new(Value::Noval));
        let cur: Rc<RefCell<Value>> = Rc::new(RefCell::new(Value::Noval));
        let (t, c) = (top.clone(), cur.clone());
        let mut copy = move |k: &Value, val: &Value, _p: &Value, _path: &[String]| -> Value {
            if k.is_noval() || matches!(val, Value::List(_) | Value::Map(_)) {
                let child = if matches!(val, Value::List(_)) {
                    Value::empty_list()
                } else {
                    Value::empty_map()
                };
                if k.is_noval() {
                    *t.borrow_mut() = child.clone();
                    *c.borrow_mut() = child;
                } else {
                    let curv = c.borrow().clone();
                    set_prop(curv, k, child.clone());
                    *c.borrow_mut() = child;
                }
            } else {
                let curv = c.borrow().clone();
                set_prop(curv, k, val.clone());
            }
            val.clone()
        };
        let _ = walk(
            vget(&vin, "src"),
            Some(&mut copy),
            None,
            as_i64_opt(&vget(&vin, "maxdepth")),
        );
        let r = top.borrow().clone();
        r
    });
    // walk.copy — deep-copy via a depth-indexed scratch list.
    run.run_set(&set!("walk", "copy"), true, "walk-copy", |vin| {
        let cur: Rc<RefCell<Vec<Value>>> = Rc::new(RefCell::new(Vec::new()));
        let c = cur.clone();
        let mut walkcopy = move |k: &Value, val: &Value, _p: &Value, path: &[String]| -> Value {
            if k.is_noval() {
                let head = match val {
                    Value::Map(_) => Value::empty_map(),
                    Value::List(_) => Value::empty_list(),
                    other => other.clone(),
                };
                *c.borrow_mut() = vec![head];
                return val.clone();
            }
            let i = path.len();
            let mut v = val.clone();
            if matches!(val, Value::List(_) | Value::Map(_)) {
                v = if is_map(val) {
                    Value::empty_map()
                } else {
                    Value::empty_list()
                };
                let mut cb = c.borrow_mut();
                while cb.len() <= i {
                    cb.push(Value::Noval);
                }
                cb[i] = v.clone();
            }
            let parent_copy = c
                .borrow()
                .get(i.saturating_sub(1))
                .cloned()
                .unwrap_or(Value::Noval);
            set_prop(parent_copy, k, v);
            val.clone()
        };
        let _ = walk(vin, Some(&mut walkcopy), None, None);
        let r = cur.borrow().first().cloned().unwrap_or(Value::Noval);
        r
    });

    // -------- merge --------------------------------------------------
    for name in ["cases", "array", "integrity"] {
        run.run_set(
            &set!("merge", name),
            true,
            &format!("merge-{name}"),
            |vin| merge(&vin, None),
        );
    }
    run.run_set(&set!("merge", "depth"), true, "merge-depth", |vin| {
        merge(&vget(&vin, "val"), as_i64_opt(&vget(&vin, "depth")))
    });
    // merge.basic is a single { in, out } object (not a `set`); handle inline.
    {
        let mb = vget(&s, "merge");
        let basic = vget(&mb, "basic");
        let bin = clone(&vget(&basic, "in"));
        let bout = fix_json(&vget(&basic, "out"), true);
        let got = fix_json(&merge(&bin, None), true);
        if got == bout {
            run.passed += 1;
        } else {
            run.failures.push(format!(
                "merge-basic: got {}, want {}",
                stringify(&got, Some(200), false),
                stringify(&bout, Some(200), false)
            ));
        }
    }

    // -------- getpath ------------------------------------------------
    run.run_set(&set!("getpath", "basic"), true, "getpath-basic", |vin| {
        get_path(&vget(&vin, "store"), &vget(&vin, "path"), None)
    });
    run.run_set(
        &set!("getpath", "relative"),
        true,
        "getpath-relative",
        |vin| {
            let dpath = match vget(&vin, "dpath") {
                Value::Str(dp) => Some(dp.split('.').map(|x| x.to_string()).collect()),
                _ => None,
            };
            let d = InjectDef {
                dparent: Some(vget(&vin, "dparent")),
                dpath,
                ..Default::default()
            };
            get_path(&vget(&vin, "store"), &vget(&vin, "path"), Some(&d))
        },
    );
    run.run_set(
        &set!("getpath", "special"),
        true,
        "getpath-special",
        |vin| {
            let d = inject_def_from_value(&vget(&vin, "inj"));
            get_path(&vget(&vin, "store"), &vget(&vin, "path"), Some(&d))
        },
    );
    run.run_set(
        &set!("getpath", "handler"),
        true,
        "getpath-handler",
        |vin| {
            // getpath({ $TOP: store, $FOO: () => 'foo' }, path, { handler: (_inj, val) => val() })
            let store_inner = vget(&vin, "store");
            let mut topmap = OrderedMap::new();
            topmap.insert("$TOP".to_string(), store_inner);
            topmap.insert(
                "$FOO".to_string(),
                Value::func(|_inj: &Inj, _v: &Value, _r: &str, _st: &Value| Value::str("foo")),
            );
            let store = Value::map(topmap);
            let handler: NativeFn =
                Rc::new(|inj: &Inj, val: &Value, _r: &str, st: &Value| -> Value {
                    match val {
                        Value::Func(f) => f(inj, &Value::Noval, "", st),
                        other => other.clone(),
                    }
                });
            let d = InjectDef {
                handler: Some(handler),
                ..Default::default()
            };
            get_path(&store, &vget(&vin, "path"), Some(&d))
        },
    );

    // -------- inject -------------------------------------------------
    {
        // inject.basic is a single { in: {val, store}, out } object.
        let basic = vget_path(&s, &["inject", "basic"]);
        let bin = vget(&basic, "in");
        let bout = fix_json(&vget(&basic, "out"), true);
        let got = fix_json(
            &inject(
                clone(&vget(&bin, "val")),
                &clone(&vget(&bin, "store")),
                None,
            ),
            true,
        );
        if got == bout {
            run.passed += 1;
        } else {
            run.failures.push(format!(
                "inject-basic: got {}, want {}",
                stringify(&got, Some(200), false),
                stringify(&bout, Some(200), false)
            ));
        }
    }
    run.run_set(&set!("inject", "string"), true, "inject-string", |vin| {
        let null_mod: Modify = Rc::new(
            |val: &Value, key: &Value, parent: &Value, _inj: &Inj, _store: &Value| {
                if let Value::Str(svv) = val {
                    if svv == NULLMARK {
                        set_prop(parent.clone(), key, Value::Null);
                    } else {
                        set_prop(
                            parent.clone(),
                            key,
                            Value::str(svv.replace(NULLMARK, "null")),
                        );
                    }
                }
            },
        );
        let d = InjectDef {
            modify: Some(null_mod),
            ..Default::default()
        };
        inject(vget(&vin, "val"), &vget(&vin, "store"), Some(&d))
    });
    run.run_set(&set!("inject", "deep"), true, "inject-deep", |vin| {
        inject(vget(&vin, "val"), &vget(&vin, "store"), None)
    });

    // -------- transform ---------------------------------------------
    {
        let basic = vget_path(&s, &["transform", "basic"]);
        let bin = vget(&basic, "in");
        let bout = fix_json(&vget(&basic, "out"), true);
        let got = match transform(
            &clone(&vget(&bin, "data")),
            &clone(&vget(&bin, "spec")),
            None,
        ) {
            Ok(v) => fix_json(&v, true),
            Err(e) => Value::str(format!("ERR:{}", e)),
        };
        if got == bout {
            run.passed += 1;
        } else {
            run.failures.push(format!(
                "transform-basic: got {}, want {}",
                stringify(&got, Some(200), false),
                stringify(&bout, Some(200), false)
            ));
        }
    }
    for (name, null_flag) in [
        ("paths", true),
        ("cmds", true),
        ("ref", true),
        ("each", true),
        ("pack", true),
        ("format", false),
        ("apply", true),
    ] {
        run.run_set_fallible(
            &set!("transform", name),
            null_flag,
            &format!("transform-{name}"),
            |vin| transform(&vget(&vin, "data"), &vget(&vin, "spec"), None).map_err(|e| e.message),
        );
    }
    run.run_set(
        &set!("transform", "modify"),
        true,
        "transform-modify",
        |vin| {
            let m: Modify = Rc::new(
                |val: &Value, key: &Value, parent: &Value, _inj: &Inj, _store: &Value| {
                    if let Value::Str(svv) = val {
                        set_prop(parent.clone(), key, Value::str(format!("@{svv}")));
                    }
                },
            );
            let d = InjectDef {
                modify: Some(m),
                ..Default::default()
            };
            match transform(&vget(&vin, "data"), &vget(&vin, "spec"), Some(&d)) {
                Ok(v) => v,
                Err(_) => Value::Noval,
            }
        },
    );

    // -------- validate -----------------------------------------------
    for name in ["basic", "invalid"] {
        run.run_set_fallible(
            &set!("validate", name),
            false,
            &format!("validate-{name}"),
            |vin| validate(&vget(&vin, "data"), &vget(&vin, "spec"), None).map_err(|e| e.message),
        );
    }
    for name in ["child", "one", "exact"] {
        run.run_set_fallible(
            &set!("validate", name),
            true,
            &format!("validate-{name}"),
            |vin| validate(&vget(&vin, "data"), &vget(&vin, "spec"), None).map_err(|e| e.message),
        );
    }
    run.run_set_fallible(
        &set!("validate", "special"),
        true,
        "validate-special",
        |vin| {
            let d = inject_def_from_value(&vget(&vin, "inj"));
            validate(&vget(&vin, "data"), &vget(&vin, "spec"), Some(&d)).map_err(|e| e.message)
        },
    );

    // -------- select -------------------------------------------------
    for name in ["basic", "operators", "edge", "alts"] {
        run.run_set(
            &set!("select", name),
            true,
            &format!("select-{name}"),
            |vin| select(&vget(&vin, "obj"), &vget(&vin, "query")),
        );
    }

    // -------- primary / SDK ------------------------------------------
    // A tiny mock SDK (mirrors ts/test/sdk.ts): check(ctx) ->
    //   { zed: 'ZED' + (opts.foo ?? '') + '_' + (ctx.meta?.bar ?? '0') }
    fn sdk_check(opts: &Value, ctx: &Value) -> Value {
        let foo = get_prop(opts, &Value::str("foo"), Value::Noval);
        let foo_s = if foo.is_nullish() {
            String::new()
        } else {
            RUSTCRATE::utility::voxgigstruct::value::js_string(&foo)
        };
        let bar = get_path(ctx, &Value::str("meta.bar"), None);
        let bar_s = if bar.is_nullish() {
            "0".to_string()
        } else {
            RUSTCRATE::utility::voxgigstruct::value::js_string(&bar)
        };
        Value::map_of([("zed".to_string(), Value::str(format!("ZED{foo_s}_{bar_s}")))])
    }
    {
        let check = vget_path(&spec, &["primary", "check"]);
        // resolve clients from DEF.client (options are inject()'d against {} — a no-op here)
        let def_clients = vget_path(&check, &["DEF", "client"]);
        let mut clients: OrderedMap<Value> = OrderedMap::new();
        if let Value::Map(m) = &def_clients {
            for (cn, cdef) in m.borrow().iter() {
                let opts = vget_path(cdef, &["test", "options"]);
                let opts = inject(clone(&opts), &Value::empty_map(), None);
                clients.insert(cn.clone(), opts);
            }
        }
        let basic = vget(&check, "basic");
        let testset = vget(&basic, "set");
        if let Some(l) = testset.as_list() {
            for (i, entry) in l.borrow().iter().enumerate() {
                let ctx = vget(entry, "ctx");
                let client = vget(entry, "client");
                let opts = match &client {
                    Value::Str(c) => clients.get(c).cloned().unwrap_or(Value::empty_map()),
                    _ => Value::empty_map(),
                };
                let res = fix_json(&sdk_check(&opts, &ctx), true);
                let want = fix_json(&vget(entry, "out"), true);
                if res == want {
                    run.passed += 1;
                } else {
                    run.failures.push(format!(
                        "check-basic#{i}: got {}, want {}",
                        stringify(&res, Some(120), false),
                        stringify(&want, Some(120), false)
                    ));
                }
            }
        }
    }

    // -------- report -------------------------------------------------
    if !run.failures.is_empty() {
        let n = run.failures.len();
        let mut msg = format!("\n{} corpus check(s) failed ({} passed):\n", n, run.passed);
        for f in run.failures.iter().take(60) {
            msg.push_str("  - ");
            msg.push_str(f);
            msg.push('\n');
        }
        if n > 60 {
            msg.push_str(&format!("  ... and {} more\n", n - 60));
        }
        panic!("{msg}");
    }
    eprintln!("corpus: {} checks passed", run.passed);
}

// Function values embedded in data: `get_elem` with a callable `alt`, and
// `$APPLY` / a user `$FORMAT` formatter — see rs/README.md "Function values".
#[test]
fn function_values() {
    // get_elem: absent element + callable alt -> alt is invoked
    assert_eq!(
        get_elem(
            &Value::empty_list(),
            &Value::Num(1.0),
            Value::func(|_i: &Inj, _v: &Value, _r: &str, _s: &Value| Value::Num(2.0)),
        ),
        Value::Num(2.0)
    );
    // present element wins over the callable alt
    assert_eq!(
        get_elem(
            &Value::list(vec![Value::Num(9.0)]),
            &Value::Num(0.0),
            Value::func(|_i: &Inj, _v: &Value, _r: &str, _s: &Value| Value::Num(2.0)),
        ),
        Value::Num(9.0)
    );

    // $APPLY: ['`$APPLY`', applyFn, child] — applyFn called with (inj, val=resolved, "", store)
    let spec = Value::list(vec![
        Value::str("`$APPLY`"),
        Value::func(|_i: &Inj, v: &Value, _r: &str, _s: &Value| {
            // v is the resolved child; double a number
            match v {
                Value::Num(n) => Value::Num(n * 2.0),
                other => other.clone(),
            }
        }),
        Value::Num(21.0),
    ]);
    let out = transform(&Value::empty_map(), &spec, None).unwrap();
    assert_eq!(out, Value::Num(42.0));

    // $FORMAT with a user function: applied per node, receives (inj, val, "", store)
    let spec = Value::list(vec![
        Value::str("`$FORMAT`"),
        Value::func(|_i: &Inj, v: &Value, _r: &str, _s: &Value| match v {
            Value::Str(s) => Value::str(format!("[{s}]")),
            other => other.clone(),
        }),
        Value::str("hi"),
    ]);
    let out = transform(&Value::empty_map(), &spec, None).unwrap();
    assert_eq!(out, Value::str("[hi]"));
}

// quiet unused-import warnings for the staged bits
#[allow(dead_code)]
fn _unused() {
    let _ = (UNDEFMARK, EXISTSMARK);
    let _ = Rc::new(RefCell::new(0));
    let _ = Value::Noval;
}
