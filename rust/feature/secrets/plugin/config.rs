// VENDORED: @voxgig/plugin sdk-20260925-1316-0 (rust/src/config.rs)
// Source: https://github.com/voxgig/plugin @ 43acbf266b0dbcf52e5ab5463d85c822da9cd234  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

use std::collections::BTreeMap;

use super::refs::{canon_ref, refname};
use super::types::{details, fail, PluginError};
use super::value::Value;

pub const MERGE_WORDS: [&str; 2] = ["replace", "append"];

pub fn normalize_config(input: &Value) -> Result<Value, PluginError> {
    let doc = input.get("doc");
    let keys = input.get("keys");
    let ikey = keys.get("instance").as_str().unwrap_or("instance").to_string();
    let dkey = keys.get("default").as_str().unwrap_or("default").to_string();
    let reserved = input.get("reserved");
    let profile = input.get("profile");

    let baseinst = doc.get(&ikey);
    let basedef = doc.get(&dkey);

    let overlay = match profile.as_str() {
        Some(p) => doc.get("profile").get(p),
        None => Value::Null,
    };
    let overlay = if overlay.as_map().is_some() {
        overlay
    } else {
        Value::map()
    };
    let overinst = overlay.get(&ikey);
    let overdef = overlay.get(&dkey);

    // Entry layers, base then overlay, each as {ref -> entry} plus the
    // order the form implies.
    let base = config_entries(&baseinst)?;
    let over = config_entries(&overinst)?;

    for group in [
        base.0.keys().cloned().collect::<Vec<String>>(),
        over.0.keys().cloned().collect::<Vec<String>>(),
        basedef.keys(),
        overdef.keys(),
    ] {
        for r in group.iter() {
            config_checkreserved(r, &reserved)?;
        }
    }

    // A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the hard
    // way: deriving order from a partial array silently dropped
    // config-activated features. Refs in the base but absent from the
    // overlay still load, in sorted position AFTER the listed ones. A
    // profile may also INTRODUCE a ref the base never declared.
    let mut order: Vec<String> = Vec::new();
    for r in over.1.iter().chain(base.1.iter()) {
        if !order.contains(r) {
            order.push(r.clone());
        }
    }

    let mut instance = Value::map();
    for (i, eref) in order.iter().enumerate() {
        let b = base.0.get(eref);
        let o = over.0.get(eref);

        let active = config_pick(o, "active", config_pick(b, "active", Value::Bool(true)));
        let start = config_pick(o, "start", config_pick(b, "start", Value::str("eager")));
        let block = config_pick(o, "order", config_pick(b, "order", Value::Null));

        let nm = refname(eref);
        let mut layers: Vec<Value> = Vec::new();
        let bd = basedef.get(&nm);
        let od = overdef.get(&nm);
        for src in [Some(&bd), b, Some(&od), o] {
            if let Some(src) = src {
                if src.has("options") {
                    layers.push(src.get("options"));
                }
            }
        }

        let mut ent = Value::map();
        ent.set("pos", Value::Num(i as f64));
        ent.set("active", active);
        ent.set("start", start);
        ent.set("optionlayers", Value::List(layers));
        if !block.is_null() {
            ent.set("order", block);
        }
        instance.set(eref, ent);
    }

    // `default` DECLARES NOTHING (§9.3). It is a base for every instance
    // of that definition; it does not create one, and an entry for a name
    // with no instances is inert rather than an error - which is what
    // makes a shared library of defaults shippable.
    let mut defout = Value::map();
    for n in basedef.keys() {
        defout.set(&n, basedef.get(&n));
    }
    for n in overdef.keys() {
        defout.set(&n, overdef.get(&n));
    }

    let mut out = Value::map();
    out.set("instance", instance);
    out.set(
        "order",
        Value::List(order.iter().map(|r| Value::str(r)).collect()),
    );
    out.set("default", defout);
    Ok(out)
}

/// Both document forms reduce to {ref -> entry} plus the order the form
/// implies: array POSITION for the array form, sorted refs for the map
/// form.
type Entries = (BTreeMap<String, Value>, Vec<String>);

fn config_entries(src: &Value) -> Result<Entries, PluginError> {
    let mut map: BTreeMap<String, Value> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();

    match src {
        Value::Null => Ok((map, order)),
        Value::List(items) => {
            for item in items.iter() {
                let eref = canon_ref(&item.get("ref"))?;
                map.insert(eref.clone(), item.clone());
                order.push(eref);
            }
            Ok((map, order))
        }
        _ => {
            // Map-form refs arrive as KEYS, through a different path than
            // an array element's `ref` field - and must canonicalize the
            // same way.
            for key in src.keys() {
                map.insert(canon_ref(&Value::str(&key))?, src.get(&key));
            }
            // Byte-wise, NOT locale-aware and NOT case-folded. All-
            // lowercase refs sort identically under all three, so only
            // mixed input discriminates: '@' is 0x40, uppercase 0x41-0x5A,
            // lowercase 0x61-0x7A. A BTreeMap over String is exactly that.
            order = map.keys().cloned().collect();
            Ok((map, order))
        }
    }
}

/// §9.1: reservation is all-or-nothing per NAME, so the tagged forms go
/// too. A configuration surface that can disable the thing reading it is
/// not a surface, it is a trap.
fn config_checkreserved(eref: &str, reserved: &Value) -> Result<(), PluginError> {
    let list = match reserved.as_list() {
        Some(l) if !l.is_empty() => l,
        _ => return Ok(()),
    };
    let name = refname(eref);
    if !list.iter().any(|r| r.as_str() == Some(name.as_str())) {
        return Ok(());
    }
    fail(
        "plugin_ref_reserved",
        &format!("ref is reserved by the host: {}", eref),
        details(&[("ref", Value::str(eref))]),
    )
}

/// PRESENCE decides, not truthiness and not null. A JSON `null` is a
/// present value in JavaScript (`undefined !== null`), so it must be one
/// here.
fn config_pick(src: Option<&Value>, key: &str, dflt: Value) -> Value {
    match src {
        Some(s) if s.has(key) => s.get(key),
        _ => dflt,
    }
}


pub fn resolve_options(input: &Value) -> Result<Value, PluginError> {
    let shape = input.get("shape");
    check_shape(&shape)?;

    let eref = canon_ref(&input.get("ref"))?;
    let name = refname(&eref);
    let doc = input.get("doc");
    let profile = input.get("profile");

    let overlay = match profile.as_str() {
        Some(p) => doc.get("profile").get(p),
        None => Value::Null,
    };
    let overlay = if overlay.as_map().is_some() {
        overlay
    } else {
        Value::map()
    };

    let layers = [
        config_defaultsof(&shape),
        input.get("hostdefaults"),
        config_optsof(&doc.get("default"), &name)?,
        config_optsof(&doc.get("instance"), &eref)?,
        config_optsof(&overlay.get("default"), &name)?,
        config_optsof(&overlay.get("instance"), &eref)?,
        input.get("env"),
        input.get("hostoptions"),
        input.get("loadoptions"),
        input.get("patch"),
    ];

    let mut out = Value::map();
    for layer in layers.iter() {
        if layer.is_null() {
            continue;
        }
        out = config_mergeone(&out, layer, &shape);
    }
    Ok(out)
}

fn config_defaultsof(shape: &Value) -> Value {
    let mut out = Value::map();
    for k in shape.keys() {
        let v = shape.get(&k);
        if v.has("$MERGE") {
            continue;
        }
        out.set(&k, v);
    }
    out
}

fn config_optsof(src: &Value, key: &str) -> Result<Value, PluginError> {
    if src.is_null() {
        return Ok(Value::Null);
    }

    if let Some(items) = src.as_list() {
        for item in items.iter() {
            if canon_ref(&item.get("ref"))? == key {
                return Ok(item.get("options"));
            }
        }
        return Ok(Value::Null);
    }

    for k in src.keys() {
        if canon_ref(&Value::str(&k))? != key {
            continue;
        }
        let entry = src.get(&k);
        return Ok(match entry {
            Value::Map(_) => entry.get("options"),
            _ => Value::Null,
        });
    }
    Ok(Value::Null)
}

fn config_mergeone(base: &Value, over: &Value, shape: &Value) -> Value {
    if over.is_null() {
        return base.clone();
    }
    let (b, o) = match (base.as_map(), over.as_map()) {
        (Some(b), Some(o)) => (b, o),
        _ => return over.clone(),
    };

    let mut out = b.clone();

    for (k, ov) in o.iter() {
        let directive = shape.get(k).get("$MERGE");
        let bv = out.get(k).cloned().unwrap_or(Value::Null);

        let merged = match &directive {
            Value::Str(s) if "replace" == s => ov.clone(),
            Value::Str(s) if "append" == s => {
                let mut list = bv.as_list().cloned().unwrap_or_default();
                match ov.as_list() {
                    Some(l) => list.extend(l.iter().cloned()),
                    None => list.push(ov.clone()),
                }
                Value::List(list)
            }
            d if d.has("deep") => config_deepto(&bv, ov, d.get("deep").as_num().unwrap_or(0.0)),
            _ => {
                // Library default: deep for maps, REPLACE for lists.
                // struct.merge is element-wise by index, which for option
                // maps is nearly always wrong - ["a"] over ["x","y","z"]
                // yielding ["a","y","z"] is the defect station hit on
                // secrets.providers.
                match (bv.as_map(), ov.as_map()) {
                    (Some(_), Some(_)) => config_mergeone(&bv, ov, &Value::Null),
                    _ => ov.clone(),
                }
            }
        };
        out.insert(k.clone(), merged);
    }
    Value::Map(out)
}

fn config_deepto(base: &Value, over: &Value, n: f64) -> Value {
    if n <= 0.0 {
        return over.clone();
    }
    let (b, o) = match (base.as_map(), over.as_map()) {
        (Some(b), Some(o)) => (b, o),
        _ => return over.clone(),
    };
    let mut out = b.clone();
    for (k, v) in o.iter() {
        let below = out.get(k).cloned().unwrap_or(Value::Null);
        out.insert(k.clone(), config_deepto(&below, v, n - 1.0));
    }
    Value::Map(out)
}

pub fn check_shape(shape: &Value) -> Result<(), PluginError> {
    if shape.as_map().is_none() {
        return Ok(());
    }

    for k in shape.keys() {
        let v = shape.get(&k);
        if !v.has("$MERGE") {
            continue;
        }
        let directive = v.get("$MERGE");

        if let Value::Str(word) = &directive {
            if MERGE_WORDS.contains(&word.as_str()) {
                continue;
            }
            return fail(
                "plugin_shape_invalid",
                &format!("invalid $MERGE directive at {}: {}", k, word),
                details(&[("key", Value::str(&k))]),
            );
        }

        if directive.has("deep") {
            let n = directive.get("deep");
            // `as_int` is Num-and-integral: `true` is a Bool variant and
            // `"2"` a Str, so the type test the dynamic ports need is the
            // match itself.
            if let Some(n) = n.as_int() {
                if 1 <= n {
                    continue;
                }
            }
            return fail(
                "plugin_shape_invalid",
                &format!("invalid $MERGE deep at {}: {}", k, n.json()),
                details(&[("key", Value::str(&k))]),
            );
        }

        return fail(
            "plugin_shape_invalid",
            &format!("invalid $MERGE directive at {}: {}", k, directive.json()),
            details(&[("key", Value::str(&k))]),
        );
    }
    Ok(())
}
