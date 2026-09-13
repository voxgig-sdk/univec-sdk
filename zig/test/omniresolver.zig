// The corpus test runner: vendored @voxgig/omni driven through its NATIVE
// API (`omni.makeRunner` / `Runner.runner` / `RunPack.runsetflagsargs`, see
// test/vendor/omni/omni.zig - that file is the authority), presented to the
// corpus drivers in the subject shapes they already use. No compat shim is
// vendored: the adapter below IS the whole bridge, per language, per the
// vendor-tag rollout (docs/design/vendor-tag-rollout.md, Decision 4). It
// supersedes test/struct_runner.zig entirely - both its engine half
// (runset/runsetAlloc/runsetEntry) and its assertion half (matchval/doMatch
// /jsonEqual, subsumed by omni.matchval / omni.deepequal).
//
// NAMED omniresolver, NOT omni: the vendored module is imported as
// `@import("omni")`, and a resolver at test/omni.zig would make
// `@import("omni")` and `@import("omni.zig")` a one-character slip apart -
// with the wrong one still compiling, because both expose `matchval`,
// `NULLMARK` and a `RunPack`. The two names cannot be confused.
//
// Zig-specific decisions, each load-bearing:
//
// 1. TWO VALUE MODELS, CONVERTED AT THE SUBJECT BOUNDARY. omni speaks
//    `std.json.Value`; the SDK and the corpus subjects speak the vendored
//    struct port's `JsonValue`, whose containers are pointer-stable
//    (*MapRef / *ListRef) because the struct API mutates through them. The
//    retiring runner converted per entry (fromStdJson in, toStdJson out)
//    and this keeps doing exactly that - there is no third model.
//
// 2. THE ARGUMENT IS WRITTEN BACK, so `match: {args: ...}` can be checked.
//    `struct.minor.setpath` asserts on all seven entries that the subject
//    rewrote the store it was handed, and `struct.merge.integrity` asserts
//    on all six that merge did NOT. Conversion is a copy, so a mutation
//    lands on the copy; the bridge therefore drives omni's `SubjectArgs`
//    form and returns the converted-back argument alongside the result.
//    The retiring runner could check neither: it ignored `match` outright.
//
// 3. A FAILURE IS A MESSAGE, NOT AN ERROR VALUE. Zig error values carry no
//    payload, so `@errorName` gives the tag and never the text an `err`
//    entry matches on. Every subject shape therefore reports failure
//    through an `errout: *?[]const u8` out-parameter. The retiring runner
//    SKIPPED every entry carrying `err` in the struct corpus (55 of them);
//    they are checked now.
//
// 4. ZERO-ARGUMENT ENTRIES (`noval`). The corpus carries entries with no
//    `in`, `args` or `ctx`, meaning "call the subject with NO argument".
//    omni's native rule passes one JSON null. The vendored struct port has
//    no NOVAL member in `JsonValue` - it cannot express absence as a value
//    - so the port's own spelling of no-value is the UNDEFMARK string, and
//    the corpus subjects (typify -> T_noval, clone -> null) already read
//    it. `Flags.noval` rewrites such entries to `args: ["__UNDEF__"]`
//    before the group runs, the same spec-rewrite go's resolver uses for
//    its NOVAL sentinel. It is opt-in per group because the port answers
//    correctly from a plain null everywhere else, and handing those groups
//    a marker string would change what they test.
//
// 5. THE CTX PUBLISH SLOTS ARE PRE-CREATED IN `contextify`. The primary
//    corpus asserts `match: {ctx: {spec|result|response: ...}}` on nine
//    entries, and omni reads that from the `entry.ctx` it recorded BEFORE
//    the call. In go or java that map is a reference and a subject just
//    writes into it; `std.json.ObjectMap` is a VALUE (its length lives in
//    the struct, not behind the pointer), so a key the subject ADDS is
//    invisible to omni's copy while a key it OVERWRITES is shared. So
//    `contextify` pre-creates the three publishable slots and the bridge
//    writes back through `getPtr` - an in-place overwrite of an existing
//    slot, which both copies see. The slots go into a FRESH map, never
//    into the one omni handed over: see `contextify` for why growing that
//    one faults the binary. Consequence, stated plainly: a ctx leaf
//    asserted as `__EXISTS__` is satisfied by the pre-created null, so
//    that ONE assertion shape (primary.makeRequest[0]) is weaker here than
//    in a reference-semantics port. Every concrete ctx leaf is checked in
//    full. The fix belongs upstream - a pointer-stable entry map in the
//    zig port, or a runner that re-reads `ctx` from the returned args.
//
// 6. THE COUNT IS THE GUARD. A runner that stops executing looks exactly
//    like a passing one, which is how two targets in this rollout went
//    green while running nothing. So every group compares the number of
//    SUBJECT INVOCATIONS against the number of entries the group declares,
//    and refuses an empty set outright; `CASES`/`GROUPS` accumulate a
//    census the suite asserts a floor on at the end.

const std = @import("std");
const omni = @import("omni");
const vs = @import("voxgig-struct");

const Allocator = std.mem.Allocator;

/// omni's value model.
pub const Json = omni.Json;

/// The SDK's and the corpus subjects' value model.
pub const JsonValue = vs.JsonValue;

pub const NULLMARK = omni.NULLMARK;
pub const UNDEFMARK = omni.UNDEFMARK;
pub const EXISTSMARK = omni.EXISTSMARK;

/// The shared corpus, compiled by the project build. Relative to the target
/// directory, which is where `zig build test` runs.
pub const TEST_JSON_FILE = "../.sdk/test/test.json";

/// The running census, across every group this test binary drove. A suite
/// asserts a floor on these at the end: a file whose test blocks were
/// deleted, or a runner that stopped executing, shows up as a number.
pub var CASES: usize = 0;
pub var GROUPS: usize = 0;

pub fn resetcensus() void {
    CASES = 0;
    GROUPS = 0;
}

// 0.16 reads files through an `std.Io` rather than free functions on
// `std.fs`. The corpus loader is test-only and has no Io of its own to
// thread through, so it uses the statically initialised singleton std
// itself falls back to.
fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The struct-corpus subject: one value in, one value out.
pub const Subject = *const fn (Allocator, JsonValue) JsonValue;

/// A subject that can FAIL with a message - `validate` and `transform`
/// answer `{out, err}`, and the corpus asserts on the text.
pub const FallibleSubject = *const fn (Allocator, JsonValue, *?[]const u8) JsonValue;

/// The primary-corpus subject: omni's own argument list (a contextified ctx
/// map, or the entry's `args`, or its `in`), the ctx view to publish back
/// for `match: {ctx: ...}`, and the SDK's own failure message.
pub const CtxSubject = *const fn (
    alloc: Allocator,
    args: []const Json,
    published: *?Json,
    errout: *?[]const u8,
) anyerror!Json;

/// Per-group run options.
pub const Flags = struct {
    /// omni's null flag: nulls (in the group AND in the result) normalise to
    /// NULLMARK, and an entry with no `out` expects one. The canonical
    /// per-group setting is the reference driver's
    /// (tm/ts/test/utility/StructUtility.test.ts).
    null_: bool = true,
    /// An entry with no `in`/`args`/`ctx` reaches the subject as the port's
    /// no-value marker rather than as one null. See decision 4.
    noval: bool = false,
    /// The label failures are reported under. Defaults to the runner's
    /// section name, which is the same for every group in a suite.
    name: ?[]const u8 = null,
};

const SubjectKind = union(enum) {
    value: Subject,
    fallible: FallibleSubject,
    ctx: CtxSubject,
};

// Per-run state, reachable from omni's hooks through their `data` pointer
// (Zig has no closures; a hook is a bare function pointer plus this).
const Host = struct {
    alloc: Allocator,
    kind: ?SubjectKind = null,
    calls: usize = 0,
};

/// The ctx facets a primary subject may publish. Pre-created by
/// `contextify` so the write-back below is an in-place overwrite - see
/// decision 5.
const CTX_SLOTS = [_][]const u8{ "spec", "result", "response" };

fn hostof(data: ?*const anyopaque) *Host {
    return @ptrCast(@alignCast(@constCast(data.?)));
}

/// Hand the subject a ctx/args[0] map that already carries the publishable
/// slots (decision 5) - built as a COPY, leaving the map omni handed over
/// untouched.
///
/// `std.json.ObjectMap` is unmanaged and by value, so growing a copy
/// reallocates the entries buffer and frees the old one, and every other
/// holder of the same struct keeps pointing into freed memory. omni is such
/// a holder: it installs this return value as `args[0]` and as `entry.ctx`,
/// but the entry's own `args` list still carries the map it was parsed with,
/// and `fail` stringifies exactly that when it reports a mismatch. Growing
/// in place therefore turned every FAILING case into a general protection
/// fault - the suite aborting instead of naming the entry that differed.
///
/// Copying keeps both sides sound: the parsed map is never touched, and the
/// map omni holds after this returns IS the map the subject is called with,
/// so `publish`'s in-place `getPtr` overwrite is visible to both.
fn contextify(self: *const omni.Provider, val: Json) Json {
    const host = hostof(self.data);
    if (.object != val) {
        return val;
    }

    var out: std.json.ObjectMap = .{};
    var it = val.object.iterator();
    while (it.next()) |field| {
        out.put(host.alloc, field.key_ptr.*, field.value_ptr.*) catch return val;
    }
    for (CTX_SLOTS) |slot| {
        if (!out.contains(slot)) {
            out.put(host.alloc, slot, Json{ .null = {} }) catch return val;
        }
    }
    return .{ .object = out };
}

/// Overwrite the pre-created ctx slots in place. Only keys that ALREADY
/// exist are written: adding one would be invisible to omni's own copy of
/// the map (decision 5), so a silent no-op is better than a silent lie.
fn publish(args: []const Json, view: Json) void {
    if (0 == args.len or .object != args[0] or .object != view) {
        return;
    }

    const target = args[0].object;
    var it = view.object.iterator();
    while (it.next()) |field| {
        if (target.getPtr(field.key_ptr.*)) |slot| {
            slot.* = field.value_ptr.*;
        }
    }
}

const OOM = "omniresolver: out of memory";

fn call(self: *const omni.SubjectArgs, args: []const Json) omni.SubjectArgsResult {
    const host = hostof(self.data);
    host.calls += 1;

    const alloc = host.alloc;
    const kind = host.kind orelse return .{ .err = "omniresolver: no subject" };

    switch (kind) {
        .ctx => |subject| {
            var view: ?Json = null;
            var errmsg: ?[]const u8 = null;
            const res = subject(alloc, args, &view, &errmsg) catch |e| {
                return .{ .err = errmsg orelse @errorName(e) };
            };
            if (errmsg) |message| {
                return .{ .err = message };
            }
            if (view) |published| {
                publish(args, published);
            }
            return .{ .ok = .{ .args = args, .res = res } };
        },

        .value, .fallible => {
            const inarg: Json = if (0 < args.len) args[0] else Json{ .null = {} };
            const inval = vs.fromStdJson(alloc, inarg) catch return .{ .err = OOM };

            var errmsg: ?[]const u8 = null;
            const out = switch (kind) {
                .value => |subject| subject(alloc, inval),
                .fallible => |subject| subject(alloc, inval, &errmsg),
                else => unreachable,
            };
            if (errmsg) |message| {
                return .{ .err = message };
            }

            const res = vs.toStdJson(alloc, out) catch return .{ .err = OOM };

            // Decision 2: hand the (possibly mutated) argument back, so
            // `match: {args: ...}` sees what the subject did with it.
            const back = alloc.alloc(Json, args.len) catch return .{ .err = OOM };
            @memcpy(back, args);
            if (0 < back.len) {
                back[0] = vs.toStdJson(alloc, inval) catch args[0];
            }

            return .{ .ok = .{ .args = back, .res = res } };
        },
    }
}

/// The number of entries a group declares, or null when it has no `set`.
pub fn setlen(group: omni.Maybe) ?usize {
    const set = omni.jget(group, "set") orelse return null;
    if (.array != set) {
        return null;
    }
    return set.array.items.len;
}

/// Normalise a group's entries for this port, before omni sees it. Two
/// rewrites, both stated in the header:
///
/// - `noval` (decision 4): an entry with no `in`, `args` or `ctx` carries the
///   port's no-value marker as its single argument.
///
/// - THE ABSENT RESULT. With the null flag OFF, canonical omni leaves a
///   missing `out` ABSENT and a canonical port answers `undefined`, so the
///   two agree. The vendored struct port has no `undefined`: `JsonValue` can
///   express a null and nothing weaker, and omni-zig's own `fixjson` returns
///   `Json{.null}` for an absent value because its signature has nowhere to
///   put absence. So an entry that asserts "the subject answered nothing"
///   asserts a NULL here - written in as an explicit `out`, in the port's own
///   vocabulary. Only for an entry that asserts nothing else: one carrying
///   `err` or `match` is already checked through another path, and giving it
///   an `out` would add an assertion the corpus never made.
///
/// Rebuilds the group; the loaded spec is never mutated.
fn prepare(alloc: Allocator, group: Json, flags: Flags) !Json {
    if (flags.null_ and !flags.noval) {
        return group;
    }

    const set = omni.jget(group, "set") orelse return group;
    if (.array != set) {
        return group;
    }

    var patched = std.json.Array.init(alloc);
    for (set.array.items) |entry| {
        if (.object != entry) {
            try patched.append(entry);
            continue;
        }

        const noargs = !omni.jhas(entry, "in") and
            !omni.jhas(entry, "args") and !omni.jhas(entry, "ctx");
        const wantnoval = flags.noval and noargs;
        const wantnull = !flags.null_ and
            !omni.jhas(entry, "out") and
            !omni.jhas(entry, "err") and
            !omni.jhas(entry, "match");

        if (!wantnoval and !wantnull) {
            try patched.append(entry);
            continue;
        }

        var copy: std.json.ObjectMap = .{};
        var it = entry.object.iterator();
        while (it.next()) |field| {
            try copy.put(alloc, field.key_ptr.*, field.value_ptr.*);
        }
        if (wantnoval) {
            try copy.put(alloc, "args", try omni.jlist(alloc, &.{omni.jstr(UNDEFMARK)}));
        }
        if (wantnull) {
            try copy.put(alloc, "out", Json{ .null = {} });
        }
        try patched.append(.{ .object = copy });
    }

    return omni.jset(alloc, group, "set", .{ .array = patched });
}

/// A loaded corpus section plus the provider that hosts the subjects.
pub const Runner = struct {
    parent: Allocator,
    arena: *std.heap.ArenaAllocator,
    alloc: Allocator,
    host: *Host,
    provider: *omni.Provider,
    inner: omni.Runner,
    pack: omni.RunPack,

    /// The message of the last failure, for the smoke test.
    failure: ?[]const u8 = null,
    /// Suppress the failure report (the smoke test EXPECTS failures).
    quiet: bool = false,

    pub fn deinit(self: *Runner) void {
        const parent = self.parent;
        const arena = self.arena;
        arena.deinit();
        parent.destroy(arena);
    }

    /// The resolved section, as loaded.
    pub fn spec(self: *const Runner) Json {
        return self.pack.spec;
    }

    /// A named group, one level down (`walk` -> `basic`). Absent when the
    /// corpus does not carry it: the SDK corpus may omit a section the
    /// upstream struct corpus has, and the corpus is the contract.
    pub fn group(self: *const Runner, section: []const u8, name: []const u8) omni.Maybe {
        return omni.jget(omni.jget(self.pack.spec, section), name);
    }

    /// A named group at the top of the section (`makeSpec` -> `basic`).
    pub fn set(self: *const Runner, name: []const u8) omni.Maybe {
        return omni.jget(self.pack.spec, name);
    }

    pub fn runset(self: *Runner, group_: omni.Maybe, subject: Subject) !void {
        return self.drive(group_, .{}, .{ .value = subject });
    }

    pub fn runsetflags(self: *Runner, group_: omni.Maybe, flags: Flags, subject: Subject) !void {
        return self.drive(group_, flags, .{ .value = subject });
    }

    pub fn runseterr(self: *Runner, group_: omni.Maybe, flags: Flags, subject: FallibleSubject) !void {
        return self.drive(group_, flags, .{ .fallible = subject });
    }

    pub fn runsetctx(self: *Runner, group_: omni.Maybe, flags: Flags, subject: CtxSubject) !void {
        return self.drive(group_, flags, .{ .ctx = subject });
    }

    fn drive(self: *Runner, group_: omni.Maybe, flags: Flags, kind: SubjectKind) !void {
        self.failure = null;

        // A group the corpus does not carry is a skip; a group it carries
        // EMPTY is a failure. The lenient (version 0) spec format lets an
        // empty set pass silently, and an emptied section is precisely the
        // regression this rollout exists to catch.
        const found = group_ orelse return error.SkipZigTest;
        const declared = setlen(found) orelse {
            self.report("omniresolver: group has no `set`", flags);
            return error.NoTestSet;
        };
        if (0 == declared) {
            self.report("omniresolver: empty test set", flags);
            return error.EmptyTestSet;
        }

        const usegroup = try prepare(self.alloc, found, flags);

        self.host.kind = kind;
        self.host.calls = 0;

        const argsubject = omni.SubjectArgs{ .call = call, .data = self.host };

        const failure = try self.pack.runsetflagsargs(
            usegroup,
            .{ .null_ = flags.null_, .name = flags.name },
            &argsubject,
        );

        if (failure) |message| {
            self.failure = message;
            if (!self.quiet) {
                std.debug.print("\n{s}\n", .{message});
            }
            return error.CorpusFailure;
        }

        // Decision 6. omni returns on the FIRST failure, so this can only
        // differ when the engine ran fewer entries than the group declares
        // - a section that silently stopped driving the subject.
        if (self.host.calls != declared) {
            const message = std.fmt.allocPrint(
                self.alloc,
                "omniresolver: {s}: ran {d} of {d} declared cases",
                .{ flags.name orelse self.pack.name, self.host.calls, declared },
            ) catch "omniresolver: case count mismatch";
            self.failure = message;
            if (!self.quiet) {
                std.debug.print("\n{s}\n", .{message});
            }
            return error.CasesNotRun;
        }

        CASES += self.host.calls;
        GROUPS += 1;
    }

    fn report(self: *Runner, message: []const u8, flags: Flags) void {
        self.failure = message;
        if (!self.quiet) {
            std.debug.print("\n{s}: {s}\n", .{ message, flags.name orelse self.pack.name });
        }
    }
};

fn build(parent: Allocator, section: []const u8, spec: ?Json) !Runner {
    const arena = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();

    const alloc = arena.allocator();

    const host = try alloc.create(Host);
    host.* = .{ .alloc = alloc };

    const provider = try alloc.create(omni.Provider);
    provider.* = .{ .contextify = contextify, .data = host };

    const inner = if (spec) |value|
        try omni.makeRunnerSpec(alloc, value, provider)
    else
        try omni.makeRunner(alloc, testIo(), TEST_JSON_FILE, provider);

    const pack = try inner.runner(section, null);

    return .{
        .parent = parent,
        .arena = arena,
        .alloc = alloc,
        .host = host,
        .provider = provider,
        .inner = inner,
        .pack = pack,
    };
}

/// A runner over the shared corpus file, resolved at one named section
/// ("struct", "primary").
pub fn makeRunner(parent: Allocator, section: []const u8) !Runner {
    return build(parent, section, null);
}

/// A runner over an in-memory spec (omni's own capability), which keeps the
/// smoke test free of fixture files.
pub fn makeRunnerSpec(parent: Allocator, spec: Json, section: []const u8) !Runner {
    return build(parent, section, spec);
}
