use std::rc::Rc;

use crate::core::context::Context;
use crate::core::helpers::{get_str, getp, getpath, ja, jo, setp, to_map};
use crate::utility::voxgigstruct as vs;
use crate::utility::voxgigstruct::Value;

pub fn make_options_util(ctx: &Rc<Context>) -> Value {
    let options = match ctx.options.borrow().clone() {
        Value::Map(m) => Value::Map(m),
        _ => Value::empty_map(),
    };

    // Merge custom utility overrides onto the utility object. Read from the
    // original options (function values are shared by reference).
    let custom_utils = to_map(&getp(&options, "utility"));
    if let Value::Map(cm) = &custom_utils {
        if let Some(utility) = ctx.utility.borrow().clone() {
            let custom = utility.custom.borrow().clone();
            for (k, v) in cm.borrow().iter() {
                setp(&custom, k, v.clone());
            }
        }
    }

    let auth_suppressed = match &options {
        Value::Map(m) => matches!(m.borrow().get("auth"), Some(Value::Null)),
        _ => false,
    };

    let mut opts = vs::clone(&options);

    if auth_suppressed {
        opts = vs::del_prop(opts, &Value::str("auth"));
    }

    let mut feature_order: Vec<String> = Vec::new();
    if let Value::List(fl) = getp(&opts, "feature") {
        let fmap = Value::empty_map();
        for entry in fl.borrow().iter() {
            if let Value::Map(_) = entry {
                if let Value::Str(nm) = getp(entry, "name") {
                    let fopts = vs::clone(entry);
                    vs::del_prop(fopts.clone(), &Value::str("name"));
                    setp(&fmap, &nm, fopts);
                    feature_order.push(nm);
                }
            }
        }
        setp(&opts, "feature", fmap);
    }

    let config = ctx.config.borrow().clone();
    let cfgopts = match to_map(&getp(&config, "options")) {
        Value::Map(m) => Value::Map(m),
        _ => Value::empty_map(),
    };

    let optspec = crate::core::schema::optspec();

    // Preserve system.fetch before merge/validate (validation strips it).
    let sys_fetch = getpath(&["system", "fetch"], &opts);

    // CLONE the config side: `config` is a per-thread singleton
    // (core::config::shared_config) and merge uses its nested maps as merge
    // TARGETS, so without this one client's options (headers, server, ...) are
    // written into the shared config and inherited by every client after it.
    let merged = vs::merge(
        &ja(vec![Value::empty_map(), vs::clone(&cfgopts), opts.clone()]), None);
    if let Ok(validated) = vs::validate(&merged, &optspec, None) {
        if let Value::Map(_) = validated {
            opts = validated;
        }
    }

    // Restore the suppression the optspec default would otherwise erase.
    if auth_suppressed {
        setp(&opts, "auth", Value::Null);
    }

    if let Value::Str(base) = getp(&opts, "base") {
        if base.contains('{') {
            let testmode = matches!(getpath(&["test", "active"], &opts), Value::Bool(true))
                || matches!(
                    getpath(&["feature", "test", "active"], &opts),
                    Value::Bool(true)
                );
            let server = getp(&opts, "server");
            let sdkname = match getpath(&["main", "name"], &config) {
                Value::Str(s) if !s.is_empty() => s,
                _ => "SDK".to_string(),
            };

            let mut resolved = String::with_capacity(base.len());
            let bytes: Vec<char> = base.chars().collect();
            let mut i = 0usize;
            while i < bytes.len() {
                if '{' != bytes[i] {
                    resolved.push(bytes[i]);
                    i += 1;
                    continue;
                }
                // A placeholder only when it closes and the name is
                // [A-Za-z0-9_]+; anything else is literal text.
                let mut j = i + 1;
                while j < bytes.len() && (bytes[j].is_ascii_alphanumeric() || '_' == bytes[j]) {
                    j += 1;
                }
                if j >= bytes.len() || '}' != bytes[j] || j == i + 1 {
                    resolved.push(bytes[i]);
                    i += 1;
                    continue;
                }
                let name: String = bytes[i + 1..j].iter().collect();
                let val = match getp(&server, &name) {
                    Value::Str(s) => s,
                    _ => String::new(),
                };
                if val.is_empty() {
                    if testmode {
                        resolved.push_str(&format!("test-{}", name));
                    } else {
                        panic!(
                            "{}: the server variable '{}' is required: the API base \
                             URL is '{}' - pass server: {{ \"{}\": \"...\" }} in the \
                             SDK options",
                            sdkname, name, base, name
                        );
                    }
                } else {
                    resolved.push_str(&val);
                }
                i = j + 1;
            }
            setp(&opts, "base", Value::str(&resolved));
        }
    }

    if !sys_fetch.is_noval() {
        let sys = getp(&opts, "system");
        if let Value::Map(_) = sys {
            setp(&sys, "fetch", sys_fetch);
        } else {
            setp(&opts, "system", jo(vec![("fetch", sys_fetch)]));
        }
    }

    let clean_keys = match getpath(&["clean", "keys"], &opts) {
        Value::Str(s) => s,
        _ => "key,token,id".to_string(),
    };

    let filtered: Vec<String> = clean_keys
        .split(',')
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .map(|p| vs::esc_re(&Value::str(p)))
        .collect();
    let keyre = filtered.join("|");

    // Resolve the feature add-order: an explicit List order (above) wins;
    // otherwise order the map test-first, then the remaining names sorted, so
    // the outcome is deterministic and `test` is always the base transport.
    if feature_order.is_empty() {
        if let Value::Map(fm) = getp(&opts, "feature") {
            let mut names: Vec<String> =
                fm.borrow().iter().map(|(k, _)| k.clone()).collect();
            names.sort();
            if names.iter().any(|n| n == "test") {
                feature_order.push("test".to_string());
                for n in names.into_iter().filter(|n| n != "test") {
                    feature_order.push(n);
                }
            } else {
                feature_order = names;
            }
            if let Some(si) = feature_order.iter().position(|n| n == "station") {
                feature_order.remove(si);
                let at = feature_order
                    .iter()
                    .position(|n| n == "test")
                    .map(|ti| ti + 1)
                    .unwrap_or(0);
                feature_order.insert(at, "station".to_string());
            }
        }
    }
    let order_list =
        Value::list(feature_order.into_iter().map(|n| Value::str(n)).collect());

    let derived_clean = if keyre.is_empty() {
        Value::empty_map()
    } else {
        jo(vec![("keyre", Value::str(keyre))])
    };
    setp(
        &opts,
        "__derived__",
        jo(vec![("clean", derived_clean), ("featureorder", order_list)]),
    );

    opts
}

/// Read a string option (helper shared by prepare utilities).
pub fn opt_str(options: &Value, key: &str) -> String {
    get_str(options, key).unwrap_or_default()
}
