// Test runner for Zig — loads build/test/test.json and drives specs
// against subject functions, mirroring the TS/Go runner pattern.

const std = @import("std");
const regex = @import("../utility/voxgigstruct/regex.zig");
const voxgig_struct = @import("voxgig-struct");

const Allocator = std.mem.Allocator;
const StdJsonValue = std.json.Value;
const JsonValue = voxgig_struct.JsonValue;

pub const NULLMARK = "__NULL__";
pub const UNDEFMARK = "__UNDEF__";
pub const EXISTSMARK = "__EXISTS__";

pub const TEST_JSON_FILE = "../.sdk/test/test.json";

// Subject that takes only a std.json.Value (for simple is* functions).
pub const Subject = *const fn (StdJsonValue) StdJsonValue;

// Subject that takes an allocator and our JsonValue type.
pub const AllocSubject = *const fn (Allocator, JsonValue) JsonValue;

/// A subject that receives the whole corpus ENTRY and returns std.json.
///
/// `published` is an out-parameter for the context the subject built. std.json
/// maps cannot be mutated in place safely from here — a put may reallocate the
/// backing store and the caller would never see it — so a section that needs a
/// `match: ctx.*` assertion hands its ctx back through this instead.
pub const EntrySubject = *const fn (
    Allocator,
    StdJsonValue,
    *?StdJsonValue,
    /// The SDK's own error message. Zig errors carry no payload, so
    /// @errorName gives the tag ("Sdk") and never the text the corpus matches
    /// on. A subject that fails writes ctx.pending_err's message here.
    *?[]const u8,
) anyerror!StdJsonValue;

pub const Spec = struct {
    data: StdJsonValue,

    pub fn get(self: Spec, key: []const u8) ?StdJsonValue {
        return switch (self.data) {
            .object => |obj| obj.get(key),
            else => null,
        };
    }
};

pub const RunPack = struct {
    spec: Spec,
    allocator: Allocator,
    file_data: []const u8,
    /// Cases actually executed, so a suite can assert it ran something.
    ran: usize = 0,
    parsed: std.json.Parsed(StdJsonValue),

    /// Run all entries in testspec.set against the subject function (no alloc, std types).
    pub fn runset(self: RunPack, testspec: StdJsonValue, subject: Subject) !void {
        try self.runsetflags(testspec, .{}, subject);
    }

    /// Run with flags (e.g. .{ .null_flag = false }).
    pub fn runsetflags(self: RunPack, testspec: StdJsonValue, flags: Flags, subject: Subject) !void {
        _ = self;
        const set = switch (testspec) {
            .object => |obj| obj.get("set") orelse return error.NoSetInSpec,
            else => return error.SpecNotObject,
        };
        const entries = switch (set) {
            .array => |arr| arr.items,
            else => return error.SetNotArray,
        };

        for (entries) |entry_val| {
            const entry = switch (entry_val) {
                .object => |obj| obj,
                else => continue,
            };

            const in_val: StdJsonValue = entry.get("in") orelse .null;
            const raw_out = entry.get("out");
            const expected: StdJsonValue = if (raw_out) |o| o else if (flags.null_flag) StdJsonValue{ .string = NULLMARK } else .null;
            const err_field = entry.get("err");

            const result = subject(in_val);
            if (err_field != null) continue;
            try checkResult(expected, result);
        }
    }

    /// Run all entries against an allocator-aware subject (uses our JsonValue type).
    pub fn runsetAlloc(self: RunPack, testspec: StdJsonValue, subject: AllocSubject) !void {
        try self.runsetAllocFlags(testspec, .{}, subject);
    }

    /// Run with flags against an allocator-aware subject.
    pub fn runsetAllocFlags(self: RunPack, testspec: StdJsonValue, flags: Flags, subject: AllocSubject) !void {
        const set = switch (testspec) {
            .object => |obj| obj.get("set") orelse return error.NoSetInSpec,
            else => return error.SpecNotObject,
        };
        const entries = switch (set) {
            .array => |arr| arr.items,
            else => return error.SetNotArray,
        };

        for (entries, 0..) |entry_val, entry_idx| {
            const entry = switch (entry_val) {
                .object => |obj| obj,
                else => continue,
            };

            const has_in = entry.get("in") != null;
            const in_val_std: StdJsonValue = entry.get("in") orelse
                if (flags.undef_as_null) .null else StdJsonValue{ .string = UNDEFMARK };

            const raw_out = entry.get("out");
            const expected: StdJsonValue = if (raw_out) |o| o else if (flags.null_flag) StdJsonValue{ .string = NULLMARK } else .null;

            const err_field = entry.get("err");
            _ = has_in;

            // Use an arena allocator for each test case.
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Convert std.json input to our JsonValue type.
            const in_val = voxgig_struct.fromStdJson(alloc, in_val_std) catch .null;

            const result_jval = subject(alloc, in_val);

            if (err_field != null) continue;

            // Convert our result back to std.json for comparison.
            const result = voxgig_struct.toStdJson(alloc, result_jval) catch StdJsonValue{ .null = {} };

            checkResult(expected, result) catch |e| {
                std.debug.print("  [test entry {d}]\n", .{entry_idx});
                return e;
            };
        }
    }

    /// Drive a section whose entries carry ctx/args/match/err.
    ///
    /// The subject receives the whole ENTRY, not the resolved args, because an
    /// args-style section has to publish the context it builds back onto the
    /// entry — a `match: ctx.*` assertion reads it from there.
    pub fn runsetEntry(self: *RunPack, testspec: StdJsonValue, subject: EntrySubject) !void {
        const set_val = switch (testspec) {
            .object => |obj| obj.get("set") orelse return,
            else => return,
        };
        if (set_val != .array) return;

        var failures: usize = 0;

        for (set_val.array.items, 0..) |entry_val, entry_idx| {
            if (entry_val != .object) continue;
            const entry = entry_val.object;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const err_field = entry.get("err");

            self.ran += 1;
            var published: ?StdJsonValue = null;
            var errmsg: ?[]const u8 = null;

            const res = subject(alloc, entry_val, &published, &errmsg) catch |e| {
                // An expected error: match its text, then any `match` block.
                if (err_field) |ef| {
                    const msg = errmsg orelse @errorName(e);
                    if (ef == .bool and ef.bool) continue;
                    if (matchval(alloc, ef, StdJsonValue{ .string = msg })) continue;
                    std.debug.print("\n  ERROR MATCH [entry {d}]: [{s}] <=> [{s}]\n", .{
                        entry_idx, fmtJson(ef), msg,
                    });
                }
                failures += 1;
                continue;
            };

            if (err_field != null) {
                std.debug.print("\n  expected an error [entry {d}]\n", .{entry_idx});
                failures += 1;
                continue;
            }

            var matched = false;

            if (entry.get("match")) |m| {
                var subj = std.json.ObjectMap.init(alloc);
                subj.put("out", res) catch {};
                if (entry.get("in")) |v| subj.put("in", v) catch {};
                if (published) |p| {
                    subj.put("ctx", p) catch {};
                } else if (entry.get("ctx")) |v| {
                    subj.put("ctx", v) catch {};
                }
                const subjval = StdJsonValue{ .object = subj };

                var path = std.ArrayList([]const u8).init(alloc);
                doMatch(alloc, m, subjval, &path) catch {
                    std.debug.print("  [entry {d}]\n", .{entry_idx});
                    failures += 1;
                    continue;
                };
                matched = true;
            }

            const raw_out = entry.get("out");

            if (raw_out) |o| {
                if (jsonEqual(o, res)) continue;
                if (o == .string and std.mem.eql(u8, o.string, NULLMARK) and res == .null) continue;
                std.debug.print("\n  FAIL [entry {d}]: expected {s} got {s}\n", .{
                    entry_idx, fmtJson(o), fmtJson(res),
                });
                failures += 1;
            } else if (!matched) {
                // NO `out` MEANS EXPECT NULL, not "assert nothing". The
                // reference sets a missing out to the null marker before
                // running, so an entry like {"ctx": {"opname": "bad"}} asserts
                // that the utility yields nothing.
                if (res == .null) continue;
                std.debug.print("\n  FAIL [entry {d}]: expected null got {s}\n", .{
                    entry_idx, fmtJson(res),
                });
                failures += 1;
            }
        }

        if (0 < failures) return error.SectionFailed;
    }

    pub fn deinit(self: *RunPack) void {
        self.parsed.deinit();
        self.allocator.free(self.file_data);
    }
};

pub const Flags = struct {
    null_flag: bool = true,
    undef_as_null: bool = true,
};

/// Load test.json and return a named top-level spec section.
///
/// makeRunner is this with "struct" baked in. The primary-utility suite needs
/// "primary" from the same file, and duplicating the load would give the two
/// suites separate copies of a corpus that is meant to be shared.
pub fn makeRunnerFor(allocator: Allocator, section: []const u8) !RunPack {
    const data = try std.fs.cwd().readFileAlloc(allocator, TEST_JSON_FILE, 10 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(StdJsonValue, allocator, data, .{});
    const root = parsed.value;

    const spec_val = switch (root) {
        .object => |obj| obj.get(section) orelse return error.NoSectionInTestJson,
        else => return error.TestJsonNotObject,
    };

    return RunPack{
        .spec = Spec{ .data = spec_val },
        .allocator = allocator,
        .file_data = data,
        .parsed = parsed,
    };
}

/// Load test.json and return the "struct" spec.
pub fn makeRunner(allocator: Allocator) !RunPack {
    const path = TEST_JSON_FILE;
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(StdJsonValue, allocator, data, .{});
    const root = parsed.value;

    const spec_val = switch (root) {
        .object => |obj| obj.get("struct") orelse return error.NoStructInTestJson,
        else => return error.TestJsonNotObject,
    };

    return RunPack{
        .spec = Spec{ .data = spec_val },
        .allocator = allocator,
        .file_data = data,
        .parsed = parsed,
    };
}

// ---- Corpus matching: matchval / doMatch ----
//
// The primary corpus asserts with `match` as often as with `out`, and its
// error expectations are regexes. runsetAlloc resolved only `in`, had no
// match support and silently skipped any entry carrying `err` — so it could
// drive the struct corpus but not this one. Semantics are the reference's:
// exact equality first, then __UNDEF__/__EXISTS__ markers, then a /regex/, and
// finally a case-insensitive substring.

fn stringifyAlloc(alloc: Allocator, v: StdJsonValue) []const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    if (v == .string) return v.string;
    std.json.stringify(v, .{}, buf.writer()) catch return "";
    return buf.items;
}

pub fn matchval(alloc: Allocator, check: StdJsonValue, base: StdJsonValue) bool {
    if (jsonEqual(check, base)) return true;

    if (check == .string) {
        const c = check.string;
        if (std.mem.eql(u8, c, UNDEFMARK)) return base == .null;
        if (std.mem.eql(u8, c, EXISTSMARK)) return base != .null;

        const basestr = stringifyAlloc(alloc, base);

        // A /pattern/ is a regex over the stringified base.
        if (2 <= c.len and c[0] == '/' and c[c.len - 1] == '/') {
            const pat = c[1 .. c.len - 1];
            var re = regex.compile(alloc, pat) orelse return false;
            defer re.deinit();
            return re.isMatch(basestr);
        }

        // Otherwise a case-insensitive substring, as the reference does.
        const lc_base = std.ascii.allocLowerString(alloc, basestr) catch return false;
        const lc_check = std.ascii.allocLowerString(alloc, c) catch return false;
        return std.mem.indexOf(u8, lc_base, lc_check) != null;
    }

    return false;
}

fn getPath(base: StdJsonValue, path: []const []const u8) StdJsonValue {
    var cur = base;
    for (path) |seg| {
        switch (cur) {
            .object => |o| cur = o.get(seg) orelse return StdJsonValue{ .null = {} },
            .array => |a| {
                const idx = std.fmt.parseInt(usize, seg, 10) catch return StdJsonValue{ .null = {} };
                if (idx >= a.items.len) return StdJsonValue{ .null = {} };
                cur = a.items[idx];
            },
            else => return StdJsonValue{ .null = {} },
        }
    }
    return cur;
}

/// Walk `check`; every LEAF must matchval against the same path in `base`.
pub fn doMatch(
    alloc: Allocator,
    check: StdJsonValue,
    base: StdJsonValue,
    path: *std.ArrayList([]const u8),
) !void {
    switch (check) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| {
                try path.append(kv.key_ptr.*);
                try doMatch(alloc, kv.value_ptr.*, base, path);
                _ = path.pop();
            }
        },
        .array => |a| {
            for (a.items, 0..) |item, i| {
                const seg = try std.fmt.allocPrint(alloc, "{d}", .{i});
                try path.append(seg);
                try doMatch(alloc, item, base, path);
                _ = path.pop();
            }
        },
        else => {
            const baseval = getPath(base, path.items);
            if (!matchval(alloc, check, baseval)) {
                std.debug.print("\n  MATCH: {s}: [{s}] <=> [{s}]\n", .{
                    joinPath(alloc, path.items),
                    fmtJson(check),
                    fmtJson(baseval),
                });
                return error.MatchMismatch;
            }
        },
    }
}

fn joinPath(alloc: Allocator, parts: []const []const u8) []const u8 {
    return std.mem.join(alloc, ".", parts) catch "?";
}

// ---- Result comparison (operates on std.json.Value) ----

fn checkResult(expected: StdJsonValue, result: StdJsonValue) !void {
    if (jsonEqual(expected, result)) return;

    if (expected == .string) {
        if (std.mem.eql(u8, expected.string, NULLMARK)) {
            if (result == .null) return;
        }
    }

    std.debug.print("\n  FAIL: expected {s} got {s}\n", .{
        fmtJson(expected),
        fmtJson(result),
    });
    return error.ResultMismatch;
}

fn fmtJson(val: StdJsonValue) []const u8 {
    // Best-effort one-line representation for diagnostic output. Uses the
    // process-wide page allocator so the lifetime is OK for a print-and-die.
    var buf = std.ArrayList(u8).init(std.heap.page_allocator);
    std.json.stringify(val, .{}, buf.writer()) catch return "?";
    return buf.items;
}

/// Deep equality for std.json.Value.
pub fn jsonEqual(a: StdJsonValue, b: StdJsonValue) bool {
    const TagType = std.meta.Tag(StdJsonValue);
    const tag_a: TagType = a;
    const tag_b: TagType = b;

    // Allow integer/float cross-comparison for numeric equality.
    if ((tag_a == .integer or tag_a == .float) and (tag_b == .integer or tag_b == .float)) {
        const fa: f64 = if (tag_a == .integer) @floatFromInt(a.integer) else a.float;
        const fb: f64 = if (tag_b == .integer) @floatFromInt(b.integer) else b.float;
        return fa == fb;
    }

    if (tag_a != tag_b) return false;

    return switch (a) {
        .null => true,
        .bool => |av| av == b.bool,
        .integer => |av| av == b.integer,
        .float => |av| av == b.float,
        .string => |av| std.mem.eql(u8, av, b.string),
        .number_string => |av| std.mem.eql(u8, av, b.number_string),
        .array => |av| {
            const bv = b.array;
            if (av.items.len != bv.items.len) return false;
            for (av.items, bv.items) |ai, bi| {
                if (!jsonEqual(ai, bi)) return false;
            }
            return true;
        },
        .object => |av| {
            const bv = b.object;
            if (av.count() != bv.count()) return false;
            var it = av.iterator();
            while (it.next()) |kv| {
                const bval = bv.get(kv.key_ptr.*) orelse return false;
                if (!jsonEqual(kv.value_ptr.*, bval)) return false;
            }
            return true;
        },
    };
}
