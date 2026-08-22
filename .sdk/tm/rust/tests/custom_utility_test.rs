// Custom utility overrides (mirrors tm/go/test/custom_utility_test.go):
// caller-supplied callables in options.utility land on utility.custom.

use RUSTCRATE::core::helpers::{call_vfn, getp, jo, vfn};
use RUSTCRATE::{test_sdk, Value};

const UTILS: [(&str, &str); 21] = [
    ("auth", "AUTH"),
    ("body", "BODY"),
    ("contextify", "CONTEXTIFY"),
    ("done", "DONE"),
    ("error", "ERROR"),
    ("findparam", "FINDPARAM"),
    ("fullurl", "FULLURL"),
    ("headers", "HEADERS"),
    ("method", "METHOD"),
    ("operator", "OPERATOR"),
    ("params", "PARAMS"),
    ("query", "QUERY"),
    ("reqform", "REQFORM"),
    ("request", "REQUEST"),
    ("resbasic", "RESBASIC"),
    ("resbody", "RESBODY"),
    ("resform", "RESFORM"),
    ("resheaders", "RESHEADERS"),
    ("response", "RESPONSE"),
    ("result", "RESULT"),
    ("spec", "SPEC"),
];

#[test]
fn custom_utility_basic() {
    let utility_opts = Value::empty_map();
    for (key, tag) in UTILS {
        let tag = tag.to_string();
        RUSTCRATE::core::helpers::setp(
            &utility_opts,
            key,
            vfn(move |_v| jo(vec![("util", Value::str(tag.clone()))])),
        );
    }

    let client = test_sdk(
        Value::Noval,
        jo(vec![
            ("apikey", Value::str("APIKEY01")),
            ("utility", utility_opts),
        ]),
    );

    let u = client.get_utility();
    let custom = u.custom.borrow().clone();

    for (key, tag) in UTILS {
        let f = getp(&custom, key);
        assert!(
            matches!(f, Value::Func(_)),
            "expected custom utility {:?} to exist",
            key
        );
        let out = call_vfn(&f, &Value::Noval);
        assert_eq!(
            getp(&out, "util"),
            Value::str(tag),
            "custom utility {:?}",
            key
        );
    }
}
