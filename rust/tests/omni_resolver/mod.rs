// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (`omni::runner::make_runner` / `RunPack::runsetflags_args`), presented
// to the corpus suites in the struct-runner shape they already use
// (`run.spec`, `run.set`, `run.run_set`, `run.run_set_fallible`,
// `run.passed`, `run.failures`). No compat shim is vendored: the adapter
// below IS the whole bridge, per language, per the vendor-tag rollout
// (docs/design/vendor-tag-rollout.md, Decision 4). It supersedes the whole
// of the retired `tests/struct_runner/mod.rs` and the corpus ENGINE half of
// `tests/common/mod.rs` (`runset`/`runset_named`/`match_deep`/`match_string`
// went with it; that file's SUPPORT half — env, sdk-test-control, ctx
// construction, the fh harness — is retained under its own name, so the
// emitted call sites did not move).
//
// It is the Rust peer of tm/csharp/test/OmniResolver.cs,
// tm/java/test/OmniResolver.java and
// tm/swift/Tests/UnivecSDKTests/OmniResolver.swift, and it follows the
// bridge voxgig/struct's own rust corpus harness already uses
// (struct/rust/corpus/tests/omni.rs) — the portable answer for a statically
// typed port with no reflection: omni's `Provider` is closure-based, so
// nothing in omni ever has to name this SDK's types.
//
// Rust-specific decisions, each load-bearing:
//
// 1. TWO VALUE MODELS, ONE CONVERSION PAIR. omni's `Json` and the SDK's
//    `voxgigstruct::Value` are different enums, so every crossing is an
//    explicit `tostruct` / `toomni`. `Json::Absent` <-> `Value::Noval` and
//    `Json::Null` <-> `Value::Null` keep the two no-value states the corpus
//    distinguishes apart — which is also why Rust needs neither go's
//    `novalargs` spec rewrite nor lua/php's compat shim for the corpus's
//    zero-argument entries (an entry with no `in`/`args`/`ctx` arrives as
//    one `Json::Absent`, and becomes exactly this port's own NOVAL).
//
// 2. ARGUMENTS ARE WRITTEN BACK. `SubjectArgs` (`Fn(&mut [Json])`) is the
//    channel omni provides for a subject that MUTATES its arguments, which
//    `match: {args: ...}` then asserts on — `struct/minor/setpath` and
//    `struct/merge/integrity` turn on it. Decision 1 handed the subject a
//    CONVERTED COPY, so every subject here runs through `runsetflags_args`
//    and the wrapper converts the (possibly mutated) `Value` arguments back
//    into omni's own slice after the call. A dynamic port's shim gets this
//    for free from shared object identity; Rust cannot.
//
// 3. `match: {ctx: ...}` IS RETARGETED ONTO `match: {args: {"0": ...}}`.
//    The one place this port cannot follow canonical omni as written, and a
//    VALUE-SEMANTICS consequence, not a choice. omni's `Json` is a plain
//    enum: `resolveargs` stores `entry.ctx` and `args[0]` as two COPIES of
//    the contextified map, and `checkresult` reads `entry.get("ctx")` for
//    the ctx base — so a subject's post-call writes (decision 2) can never
//    reach the copy `entry.ctx` holds, and nine `primary` entries assert
//    exactly that post-call state. args[0] IS the ctx of a ctx entry (omni
//    itself sets `args = [entry.get("ctx")]`), so moving the assertion from
//    `ctx` to `args.0` reads the SAME map, post-call, and preserves every
//    leaf: nothing is dropped, weakened or skipped. `retargetctx` below does
//    that rewrite on the spec handed to the engine. Swift faces the identical
//    problem and answers it identically; the upstream fix is for the Rust
//    port's `drive` to re-point `entry.ctx` at the returned `args[0]`, the
//    way JS object identity does implicitly — filed as a follow-up, not
//    worked around by editing a vendored file.
//
// 4. NUMBERS NEED NOTHING. omni's parser reads every JSON number as `f64`
//    and this port's `Value::Num` is also `f64` — unlike go/csharp/java,
//    where an integral double had to be narrowed before a subject saw it.
//
// 5. KEY ORDER. omni models a map as a `BTreeMap`, which sorts; this port's
//    `OrderedMap` preserves insertion order. Every map in the shared corpus
//    is already in sorted key order, so the round-trip is lossless over it —
//    but an out-of-order map authored later WOULD be reordered on the way
//    in, and `raw_unsorted_keys` below is the tripwire that says so instead
//    of failing an order-sensitive subject (`keysof`, `items`, `stringify`)
//    with a mystery diff. It reads the corpus FILE with its own
//    order-preserving scanner and never touches `Json`: a check fed by
//    omni's parser would be comparing an already-sorted map against itself
//    and could not fail. See `corpus_maps_are_in_sorted_key_order`.
//
// 7. WHAT RAN IS COUNTED, NOT WHAT WAS DECLARED. `drive` counts SUBJECT
//    INVOCATIONS, not `entrycount(set)`: a number derived from the spec
//    cannot tell a working engine from a disconnected one, and would read as
//    evidence while proving nothing. It also compares the two and fails the
//    group when they differ. `report` then refuses to pass on a group that
//    is absent from the corpus, or present in the corpus but driven by
//    nothing — the two ways a suite quietly stops checking.
//
// 6. FAILURES ARE ACCUMULATED, NOT RAISED. omni stops a group at its first
//    bad entry and returns an `OmniError`; the struct suite reports the whole
//    corpus in one panic at the end. `drive` records the message and carries
//    on, so one run still names every broken GROUP.

#![allow(dead_code)]
// The vendored port re-exports its whole surface; a test crate uses part of
// it, and the rest must not warn. The attributes go on the module
// DECLARATION - a vendored file is never edited.
#![allow(unused_imports)]

#[path = "../vendor/omni/mod.rs"]
pub mod omni;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::rc::Rc;

pub use omni::json::Json;
pub use omni::runner::{Flags, OmniError, Provider, RunPack, SpecRef, Subject, SubjectArgs};
pub use omni::util::{EXISTSMARK, NULLMARK, UNDEFMARK};

use univec_sdk::utility::voxgigstruct::ordered_map::OrderedMap;
use univec_sdk::utility::voxgigstruct::value::Value;
use univec_sdk::utility::voxgigstruct::InjectDef;
use univec_sdk::UnivecError;

// ---------------------------------------------------------------------------
// The two value models (decision 1)
// ---------------------------------------------------------------------------

/// omni's model -> this SDK's.
pub fn tostruct(val: &Json) -> Value {
    match val {
        Json::Absent => Value::Noval,
        Json::Null => Value::Null,
        Json::Bool(flag) => Value::Bool(*flag),
        Json::Num(num) => Value::Num(*num),
        Json::Str(text) => Value::Str(text.clone()),
        Json::List(items) => Value::list(items.iter().map(tostruct).collect()),
        Json::Map(entries) => {
            let mut map = OrderedMap::new();
            for (key, entry) in entries.iter() {
                map.insert(key.clone(), tostruct(entry));
            }
            Value::map(map)
        }
    }
}

/// This SDK's model -> omni's.
///
/// `Value::Func` has no JSON shape at all. It reaches here only when a corpus
/// entry puts a callable in data (`get_elem` with a callable `alt`, `$APPLY`,
/// a user `$FORMAT`), and in every such case the corpus asserts on what the
/// call RETURNED, not on the callable. `Json::Absent` is the honest answer:
/// it is what omni's own model says about a value that is not JSON, and
/// omni's `fixjson` then renders it as NULLMARK under the null flag — the
/// same place the retired hand-written `fix_json` put it.
pub fn toomni(val: &Value) -> Json {
    match val {
        Value::Noval => Json::Absent,
        Value::Null => Json::Null,
        Value::Bool(flag) => Json::Bool(*flag),
        Value::Num(num) => Json::Num(*num),
        Value::Str(text) => Json::Str(text.clone()),
        Value::List(items) => Json::List(items.borrow().iter().map(toomni).collect()),
        Value::Map(entries) => {
            let mut map = BTreeMap::new();
            for (key, entry) in entries.borrow().iter() {
                map.insert(key.clone(), toomni(entry));
            }
            Json::Map(map)
        }
        Value::Func(_) => Json::Absent,
        Value::Sentinel(_) => Json::Absent,
    }
}

/// The tripwire for decision 5: how many maps the raw corpus scan inspected,
/// and the first one whose keys are NOT in sorted order.
pub struct KeyOrderScan {
    /// Maps inspected. Reported so a scan that read nothing cannot pass as a
    /// scan that found nothing.
    pub maps: usize,
    /// `<dotted path>: [keys as authored]` for the first offender.
    pub unsorted: Option<String>,
}

/// Scan RAW JSON TEXT for a map whose keys are not in sorted order.
///
/// This deliberately does NOT go through `omni::runner::loadspec`: omni's
/// `Json::Map` is a `BTreeMap`, so a parse has already sorted every map and
/// the disorder this exists to catch is gone before the check can see it. A
/// tripwire fed by the thing it is watching cannot fire, so the scanner
/// below walks the file itself and keeps keys in the order they were
/// authored. `String`'s ordering is byte-lexicographic on UTF-8, which is
/// exactly the ordering a `BTreeMap<String, _>` imposes, so a sorted scan
/// means a lossless crossing.
///
/// Panics on malformed JSON: a corpus this cannot parse must be loud, not a
/// silent zero-map pass.
pub fn raw_unsorted_keys(text: &str) -> KeyOrderScan {
    let mut scan = RawScan {
        src: text.as_bytes(),
        pos: 0,
        maps: 0,
        path: Vec::new(),
        unsorted: None,
    };
    scan.ws();
    scan.value();
    scan.ws();
    if scan.pos != scan.src.len() {
        scan.bail("trailing input after the top-level value");
    }
    KeyOrderScan {
        maps: scan.maps,
        unsorted: scan.unsorted,
    }
}

/// A structure-only JSON reader: it builds no values, it only walks the text
/// and records the key order of every object it passes through.
struct RawScan<'a> {
    src: &'a [u8],
    pos: usize,
    maps: usize,
    path: Vec<String>,
    unsorted: Option<String>,
}

impl<'a> RawScan<'a> {
    fn bail(&self, why: &str) -> ! {
        panic!(
            "corpus key-order scan: {} at byte {} (path {:?})",
            why,
            self.pos,
            self.path.join(".")
        )
    }

    fn peek(&self) -> u8 {
        if self.pos < self.src.len() {
            self.src[self.pos]
        } else {
            0
        }
    }

    fn ws(&mut self) {
        while self.pos < self.src.len() {
            match self.src[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn expect(&mut self, want: u8) {
        if self.peek() != want {
            self.bail(&format!("expected {:?}", want as char));
        }
        self.pos += 1;
    }

    fn value(&mut self) {
        match self.peek() {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => {
                self.string();
            }
            b't' => self.literal(b"true"),
            b'f' => self.literal(b"false"),
            b'n' => self.literal(b"null"),
            b'-' | b'0'..=b'9' => self.number(),
            _ => self.bail("not a JSON value"),
        }
    }

    fn literal(&mut self, want: &[u8]) {
        if self.src.len() < self.pos + want.len() || &self.src[self.pos..self.pos + want.len()] != want {
            self.bail("bad literal");
        }
        self.pos += want.len();
    }

    fn number(&mut self) {
        let start = self.pos;
        while self.pos < self.src.len() {
            match self.src[self.pos] {
                b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9' => self.pos += 1,
                _ => break,
            }
        }
        if start == self.pos {
            self.bail("empty number");
        }
    }

    /// A JSON string, unescaped — a key must be compared as the DECODED text,
    /// which is what a `BTreeMap` would hold.
    fn string(&mut self) -> String {
        self.expect(b'"');
        let mut out = String::new();
        loop {
            if self.pos >= self.src.len() {
                self.bail("unterminated string");
            }
            let byte = self.src[self.pos];
            self.pos += 1;
            match byte {
                b'"' => return out,
                b'\\' => {
                    if self.pos >= self.src.len() {
                        self.bail("unterminated escape");
                    }
                    let esc = self.src[self.pos];
                    self.pos += 1;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let code = self.hex4();
                            // A surrogate pair is two \u escapes; the corpus has
                            // none, but decode them rather than mis-order one.
                            if (0xD800..0xDC00).contains(&code) {
                                if b'\\' == self.peek() {
                                    self.pos += 1;
                                    self.expect(b'u');
                                    let low = self.hex4();
                                    let joined =
                                        0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                                    out.push(
                                        char::from_u32(joined)
                                            .unwrap_or_else(|| self.bail("bad surrogate pair")),
                                    );
                                } else {
                                    self.bail("lone high surrogate");
                                }
                            } else {
                                out.push(
                                    char::from_u32(code)
                                        .unwrap_or_else(|| self.bail("bad \\u escape")),
                                );
                            }
                        }
                        _ => self.bail("unknown escape"),
                    }
                }
                _ => {
                    // Copy the whole UTF-8 sequence, not just its lead byte.
                    let width = utf8width(byte);
                    let end = self.pos - 1 + width;
                    if self.src.len() < end {
                        self.bail("truncated UTF-8 in string");
                    }
                    match std::str::from_utf8(&self.src[self.pos - 1..end]) {
                        Ok(text) => out.push_str(text),
                        Err(_) => self.bail("invalid UTF-8 in string"),
                    }
                    self.pos = end;
                }
            }
        }
    }

    fn hex4(&mut self) -> u32 {
        if self.src.len() < self.pos + 4 {
            self.bail("truncated \\u escape");
        }
        let text = std::str::from_utf8(&self.src[self.pos..self.pos + 4])
            .unwrap_or_else(|_| self.bail("bad \\u escape"));
        let code = u32::from_str_radix(text, 16).unwrap_or_else(|_| self.bail("bad \\u escape"));
        self.pos += 4;
        code
    }

    fn array(&mut self) {
        self.expect(b'[');
        self.ws();
        if b']' == self.peek() {
            self.pos += 1;
            return;
        }
        let mut index = 0usize;
        loop {
            self.path.push(index.to_string());
            self.ws();
            self.value();
            self.path.pop();
            self.ws();
            match self.peek() {
                b',' => {
                    self.pos += 1;
                    index += 1;
                }
                b']' => {
                    self.pos += 1;
                    return;
                }
                _ => self.bail("expected ',' or ']'"),
            }
        }
    }

    fn object(&mut self) {
        self.expect(b'{');
        self.maps += 1;
        let mut keys: Vec<String> = Vec::new();
        self.ws();
        if b'}' == self.peek() {
            self.pos += 1;
            self.checkorder(&keys);
            return;
        }
        loop {
            self.ws();
            let key = self.string();
            keys.push(key.clone());
            self.ws();
            self.expect(b':');
            self.ws();
            self.path.push(key);
            self.value();
            self.path.pop();
            self.ws();
            match self.peek() {
                b',' => self.pos += 1,
                b'}' => {
                    self.pos += 1;
                    self.checkorder(&keys);
                    return;
                }
                _ => self.bail("expected ',' or '}'"),
            }
        }
    }

    fn checkorder(&mut self, keys: &[String]) {
        if self.unsorted.is_some() {
            return;
        }
        let mut sorted = keys.to_vec();
        sorted.sort();
        if keys != sorted.as_slice() {
            self.unsorted = Some(format!("{}: {:?}", self.path.join("."), keys));
        }
    }
}

fn utf8width(lead: u8) -> usize {
    if 0xF0 <= lead {
        4
    } else if 0xE0 <= lead {
        3
    } else if 0xC0 <= lead {
        2
    } else {
        1
    }
}

// ---------------------------------------------------------------------------
// Spec access
// ---------------------------------------------------------------------------

/// The shared corpus, compiled by the project build. `CARGO_MANIFEST_DIR` is
/// the SDK's own `rust/` directory, and the corpus sits beside it.
pub fn spec_path() -> String {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("..");
    path.push(".sdk");
    path.push("test");
    path.push("test.json");
    path.to_string_lossy().into_owned()
}

/// The whole corpus, as omni loaded it.
pub fn corpus() -> Json {
    omni::runner::loadspec(SpecRef::Path(spec_path()))
        .unwrap_or_else(|err| panic!("omni: {}", err.message))
}

/// A child node by key (absent when missing).
pub fn jget(val: &Json, key: &str) -> Json {
    val.get(key)
}

/// A child node by path.
pub fn jpath(val: &Json, keys: &[&str]) -> Json {
    let mut current = val.clone();
    for key in keys {
        current = current.get(key);
    }
    current
}

/// How many entries a group declares.
pub fn entrycount(set: &Json) -> usize {
    set.get("set").aslist().map(|list| list.len()).unwrap_or(0)
}

// ---------------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------------

/// What the runner returns for one named spec section — the struct-runner
/// shape the corpus call sites consume.
pub struct Run {
    pack: RunPack,
    /// The whole corpus (sections outside this one: `DEF` blocks, the
    /// `primary/check` client group the struct suite drives by hand).
    pub all: Json,
    /// The resolved section.
    pub spec: Json,
    pub failures: Vec<String>,
    pub passed: usize,
    /// Groups absent from THIS SDK's corpus subset, named so a run reports
    /// what it did not check rather than passing in silence. `report`
    /// FAILS on any name here that the suite did not declare expected.
    pub skipped: Vec<String>,
    /// Every group label the suite ASKED for, present or absent. `report`
    /// checks it against the groups the corpus actually carries, so a
    /// corpus group that nothing drives is a failure rather than a silence.
    pub driven: Vec<String>,
}

impl Run {
    /// A runner over one named section of the shared corpus.
    pub fn section(name: &str) -> Run {
        Run::over(corpus(), name)
    }

    /// A runner over an in-memory spec — omni's own capability, which keeps
    /// the smoke test free of a fixture file.
    pub fn over(all: Json, name: &str) -> Run {
        let runner = omni::runner::make_runner(all.clone(), Provider::default())
            .unwrap_or_else(|err| panic!("omni: {}", err.message));
        let pack = runner
            .runner(name, None)
            .unwrap_or_else(|err| panic!("omni: {}", err.message));

        Run {
            spec: pack.spec.clone(),
            pack,
            all,
            failures: Vec::new(),
            passed: 0,
            skipped: Vec::new(),
            driven: Vec::new(),
        }
    }

    /// A named group of the resolved section.
    pub fn set(&self, keys: &[&str]) -> Json {
        jpath(&self.spec, keys)
    }

    /// Run one group whose subject cannot fail.
    pub fn run_set<F>(&mut self, set: &Json, nullflag: bool, label: &str, subject: F)
    where
        F: FnMut(Value) -> Value + 'static,
    {
        let cell = Rc::new(std::cell::RefCell::new(subject));
        self.drive(set, nullflag, label, move |args: &mut [Json]| {
            let input = tostruct(args.first().unwrap_or(&Json::Absent));
            let result = (cell.borrow_mut())(input.clone());
            writeback(args, 0, &input);
            Ok(toomni(&result))
        });
    }

    /// Run one group whose subject may fail, which the corpus asserts on
    /// with `err`.
    pub fn run_set_fallible<F>(&mut self, set: &Json, nullflag: bool, label: &str, subject: F)
    where
        F: FnMut(Value) -> Result<Value, String> + 'static,
    {
        let cell = Rc::new(std::cell::RefCell::new(subject));
        self.drive(set, nullflag, label, move |args: &mut [Json]| {
            let input = tostruct(args.first().unwrap_or(&Json::Absent));
            let result = (cell.borrow_mut())(input.clone());
            writeback(args, 0, &input);
            result.map(|val| toomni(&val))
        });
    }

    /// Run one group whose subject takes omni's whole argument list and may
    /// fail with an SDK error. This is the shape the `primary` suite needs:
    /// a `ctx` entry arrives as `args[0]`, a MAP, which the call site turns
    /// into a typed `Context` and writes observable state back into
    /// (decisions 2 and 3).
    pub fn run_set_args<F>(&mut self, set: &Json, nullflag: bool, label: &str, subject: F)
    where
        F: FnMut(&mut Vec<Value>) -> Result<Value, UnivecError> + 'static,
    {
        let cell = Rc::new(std::cell::RefCell::new(subject));
        self.drive(set, nullflag, label, move |args: &mut [Json]| {
            let mut input: Vec<Value> = args.iter().map(tostruct).collect();
            let result = (cell.borrow_mut())(&mut input);
            for (index, val) in input.iter().enumerate() {
                writeback(args, index, val);
            }
            result.map(|val| toomni(&val)).map_err(|err| err.msg)
        });
    }

    /// Hand one group to omni and record the outcome.
    fn drive<F>(&mut self, set: &Json, nullflag: bool, label: &str, subject: F)
    where
        F: Fn(&mut [Json]) -> Result<Json, String> + 'static,
    {
        self.driven.push(label.to_string());

        // A section this SDK's corpus subset does not carry. Named, not
        // silent: `report` fails unless the suite declared this skip.
        if set.isabsent() {
            self.skipped.push(label.to_string());
            return;
        }

        let flags = Flags {
            null: nullflag,
            name: Some(label.to_string()),
        };
        let count = entrycount(set);
        let usespec = retargetctx(set);

        // Decision 7: count SUBJECT INVOCATIONS. `entrycount` says what the
        // corpus declares, which a disconnected engine would report just as
        // happily; this says what actually reached a subject.
        let calls = Rc::new(std::cell::Cell::new(0usize));
        let seen = calls.clone();
        let usesubject: SubjectArgs = Rc::new(move |args: &mut [Json]| {
            seen.set(seen.get() + 1);
            subject(args)
        });

        match self.pack.runsetflags_args(&usespec, &flags, &usesubject) {
            Ok(()) => {
                let ran = calls.get();
                if ran != count {
                    self.failures.push(format!(
                        "{}: the engine reported success after running {} of the {} \
                         entries the corpus declares",
                        label, ran, count
                    ));
                }
                self.passed += ran;
            }
            Err(err) => self.failures.push(err.message.replace('\n', " | ")),
        }
    }

    /// Every `<category>-<group>` in this section that carries a non-empty
    /// `set` — the groups a suite over this section is expected to drive.
    ///
    /// Shape-specific: it assumes the `struct` section's two levels
    /// (`<category>.<group>.set`) and the `"<category>-<group>"` labels the
    /// struct suite passes to `run_set`. The `primary` section nests
    /// differently (`primary.<name>.basic`) and labels its groups `<name>`,
    /// so it guards zero-case runs in `runsection` instead — see
    /// tests/primary_utility_test.rs.
    pub fn corpus_groups(&self) -> Vec<(String, usize)> {
        let mut found: Vec<(String, usize)> = Vec::new();
        let categories = match self.spec.asmap() {
            Some(map) => map,
            None => return found,
        };
        for (category, node) in categories.iter() {
            let groups = match node.asmap() {
                Some(map) => map,
                // `<category>.name` is a string and `<category>.set` an empty
                // list; neither is a group.
                None => continue,
            };
            for (name, group) in groups.iter() {
                let count = entrycount(group);
                if group.ismap() && 0 < count {
                    found.push((format!("{}-{}", category, name), count));
                }
            }
        }
        found
    }

    /// Fail the test with every accumulated failure, or report the count.
    ///
    /// `expectedskips` names the groups THIS SDK's corpus subset does not
    /// carry. It is exhaustive in both directions: a group that goes absent
    /// without being listed fails, and a listed group that is no longer
    /// absent fails too. Without that a renamed or deleted group would take
    /// its whole check count with it and the suite would still say `ok` —
    /// the exact silence the shared oracle exists to prevent.
    pub fn report(&self, what: &str, expectedskips: &[&str]) {
        let mut problems: Vec<String> = self.failures.clone();

        for label in self.skipped.iter() {
            if !expectedskips.contains(&label.as_str()) {
                problems.push(format!(
                    "{}: ABSENT from the corpus, so it ran ZERO checks — a renamed or \
                     deleted group. Restore it, or add it to the expected-skip list.",
                    label
                ));
            }
        }
        for label in expectedskips.iter() {
            if !self.skipped.iter().any(|name| name == label) {
                problems.push(format!(
                    "{}: listed as an expected skip but was not skipped — either the \
                     corpus now carries it (drop it from the expected-skip list) or the \
                     suite stopped asking for it.",
                    label
                ));
            }
        }
        for (label, count) in self.corpus_groups() {
            if !self.driven.iter().any(|name| *name == label) {
                problems.push(format!(
                    "{}: the corpus carries this group ({} entries) but NOTHING in this \
                     suite drives it — wire up a subject, or the entries are dead weight.",
                    label, count
                ));
            }
        }

        if !problems.is_empty() {
            let total = problems.len();
            let mut message = format!(
                "\n{} corpus problem(s) ({} checks actually ran):\n",
                total, self.passed
            );
            for problem in problems.iter().take(60) {
                message.push_str("  - ");
                message.push_str(problem);
                message.push('\n');
            }
            if 60 < total {
                message.push_str(&format!("  ... and {} more\n", total - 60));
            }
            panic!("{message}");
        }

        if !self.skipped.is_empty() {
            eprintln!(
                "{}: skipped (declared absent from this corpus subset): {:?}",
                what, self.skipped
            );
        }
        eprintln!("{}: {} checks passed", what, self.passed);
    }
}

/// Write one converted argument back into omni's own slice (decision 2).
fn writeback(args: &mut [Json], index: usize, val: &Value) {
    if let Some(slot) = args.get_mut(index) {
        *slot = toomni(val);
    }
}

/// Retarget `match: {ctx: ...}` onto `match: {args: {"0": ...}}` — decision 3.
/// Only when the entry HAS a ctx or args (so args[0] is that map) and the
/// check does not already assert on `args`.
fn retargetctx(testspec: &Json) -> Json {
    let set = match testspec.get("set") {
        Json::List(list) => list,
        _ => return testspec.clone(),
    };

    let mut out: Vec<Json> = Vec::with_capacity(set.len());
    for rawentry in set.iter() {
        let check = rawentry.get("match");
        if rawentry.ismap()
            && check.ismap()
            && check.has("ctx")
            && !check.has("args")
            && (rawentry.has("ctx") || rawentry.has("args"))
        {
            let mut newcheck = BTreeMap::new();
            if let Json::Map(fields) = &check {
                for (key, val) in fields.iter() {
                    // Drop the original leaf: it would read the stale
                    // pre-call copy omni keeps in `entry.ctx`.
                    if "ctx" != key {
                        newcheck.insert(key.clone(), val.clone());
                    }
                }
            }
            let mut byindex = BTreeMap::new();
            byindex.insert("0".to_string(), check.get("ctx"));
            newcheck.insert("args".to_string(), Json::Map(byindex));

            let mut entry = BTreeMap::new();
            if let Json::Map(fields) = rawentry {
                for (key, val) in fields.iter() {
                    entry.insert(key.clone(), val.clone());
                }
            }
            entry.insert("match".to_string(), Json::Map(newcheck));
            out.push(Json::Map(entry));
            continue;
        }
        out.push(rawentry.clone());
    }

    let mut spec = BTreeMap::new();
    if let Json::Map(fields) = testspec {
        for (key, val) in fields.iter() {
            spec.insert(key.clone(), val.clone());
        }
    }
    spec.insert("set".to_string(), Json::List(out));
    Json::Map(spec)
}

// ---------------------------------------------------------------------------
// Corpus-entry helpers, retained from the retired struct_runner
// ---------------------------------------------------------------------------

/// Raw field extraction from a corpus entry, in this SDK's value model:
/// preserves a stored JSON null so a field declared `null` (`{val: null}`)
/// reaches the subject as `Value::Null` and is not silently dropped.
pub fn vget(val: &Value, key: &str) -> Value {
    univec_sdk::utility::voxgigstruct::lookup(val, &Value::str(key))
}

pub fn vget_path(val: &Value, keys: &[&str]) -> Value {
    let mut current = val.clone();
    for key in keys {
        current = vget(&current, key);
    }
    current
}

pub fn as_i64_opt(val: &Value) -> Option<i64> {
    match val {
        Value::Num(num) => Some(*num as i64),
        _ => None,
    }
}

pub fn as_str_opt(val: &Value) -> Option<String> {
    match val {
        Value::Str(text) => Some(text.clone()),
        _ => None,
    }
}

pub fn b(flag: bool) -> Value {
    Value::Bool(flag)
}

/// The `fixjson` of the corpus's own comparison boundary, for the handful of
/// corpus nodes that are a single `{in, out}` object rather than a `set` and
/// so never reach omni (`merge/basic`, `inject/basic`, `transform/basic`,
/// `walk/log`). omni does exactly this to everything it runs.
pub fn fix_json(val: &Value, nullflag: bool) -> Value {
    tostruct(&omni::runner::fixjson(
        &toomni(val),
        &Flags {
            null: nullflag,
            name: None,
        },
    ))
}

pub fn inject_def_from_value(val: &Value) -> InjectDef {
    let mut def = InjectDef::default();
    if let Value::Map(_) = val {
        let key = vget(val, "key");
        if !key.is_noval() {
            def.key = Some(key);
        }
        let meta = vget(val, "meta");
        if !meta.is_noval() {
            def.meta = Some(meta);
        }
        let base = vget(val, "base");
        if let Value::Str(text) = base {
            def.base = Some(text);
        }
        let dparent = vget(val, "dparent");
        if !dparent.is_noval() {
            def.dparent = Some(dparent);
        }
        let dpath = vget(val, "dpath");
        if let Value::Str(text) = dpath {
            def.dpath = Some(text.split('.').map(|part| part.to_string()).collect());
        } else if let Value::List(list) = &dpath {
            def.dpath = Some(
                list.borrow()
                    .iter()
                    .map(|part| as_str_opt(part).unwrap_or_default())
                    .collect(),
            );
        }
    }
    def
}
