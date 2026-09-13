// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (zig/plugins/httpjson.zig)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
//! One JSON round-trip, for the plugins that talk to a vault over HTTP -
//! and the small helpers every plugin shares: address trimming, the
//! environment fallback, token expiry, escaping, and JSON writing.
//!
//! FOR WRITING A PLUGIN, NEVER FOR THE CORE. Nothing under `src/` reaches
//! this file: it is the HTTP client, and what makes a kind built in is
//! that it needs no socket. A port of go/plugins/httpjson, which serves
//! the same nine plugins there.
//!
//! std ships both an HTTP client and TLS (std.crypto.tls), so this port
//! needs neither a third-party crate nor a hand-rolled protocol: the whole
//! file is a thin, opinionated wrapper that turns std.http.Client into the
//! `{status, body}` pair every port's `fetchjson` returns.
//!
//! Opinionated in three ways, all of them the canonical's:
//!
//!   - A redirect is never followed. A vault API does not legitimately
//!     redirect, and a followed one would carry X-Vault-Token to the
//!     redirect's host (and could downgrade https to http), which
//!     `checkaddr` - it only ever sees the CONFIGURED address - cannot see.
//!   - A network failure is an ERROR, never a miss: an unreachable store is
//!     a store that could not answer.
//!   - A 200 whose body is not JSON is an error too. The status promised
//!     JSON; treating an incoherent answer as a miss would fall through to
//!     a weaker store. Error statuses may carry any body, so they are
//!     decided on status alone.

const std = @import("std");

const sekreto = @import("sekreto");

const Allocator = std.mem.Allocator;

pub const Header = std.http.Header;

/// How long reaching a vault may take before it is treated as unreachable.
/// Ports carry the same bound.
///
/// Applied TWICE, in two different ways, because std applies it neither
/// time and the two halves of a request fail differently.
///
/// `ConnectTcpOptions` has a `timeout` field and `connectTcpOptions` never
/// reads it: in Zig 0.16 the whole of `std/http/Client.zig` mentions
/// `timeout` exactly once, at the field's own declaration, and the body
/// calls `host.connect(io, port, .{ .mode = .stream })` without it. Passing
/// it did nothing. This port therefore had NO bound of any kind while its
/// code and its README both said it had one - measured: still blocked at
/// 35s against a server that accepted and went silent, where every other
/// port gave up at 10.
///
///   - The CONNECT is bounded by racing it against a sleep of this length
///     and cancelling the loser: see `dial`. Nothing shorter works, because
///     until the connect returns there is no socket to bound.
///   - Everything AFTER the connect is bounded by `Watchdog`, which shuts
///     the socket down once this long has passed.
///
/// The watchdog's bound is TOTAL - it is wall-clock from the moment the
/// connection is up, not a per-read timer that a trickle of bytes resets.
/// That makes this port and Go the only two of the twelve that cut a server
/// answering 200 and then dribbling its body one byte at a time; measured
/// at 10.05s here against 30s-and-still-going for the other ten.
pub const CONNECT_TIMEOUT_MS = 10_000;

/// How much of a response body will be read before the store is treated as
/// having answered incoherently. Ports carry the same bound.
///
/// Far above anything real - the largest legitimate payload this library
/// fetches is Doppler's whole-config download, measured in kilobytes.
///
/// This port needs the bound most. It advertises gzip and deflate and
/// decompresses transparently (see readerDecompressing below), so a hostile
/// endpoint does not have to SEND gigabytes: a few hundred kilobytes of
/// zeros expands to gigabytes in this process's heap, and the watchdog only
/// bounds the time, not the allocation.
const MAXBODY: u64 = 8 * 1024 * 1024;

/// Bounds one request by shutting its socket down if it outlasts
/// CONNECT_TIMEOUT_MS.
///
/// A thread per request is a real cost, and it buys the only bound this
/// port can have: see CONNECT_TIMEOUT_MS for why the socket option and the
/// std timeout field are both unavailable. The wait is in short steps so a
/// request that finishes early is not held up by its own watchdog.
const Watchdog = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    done: std.atomic.Value(bool) = .init(false),

    const STEP_MS = 50;

    fn run(self: *Watchdog) void {
        var waited: u64 = 0;
        while (waited < CONNECT_TIMEOUT_MS) : (waited += STEP_MS) {
            if (self.done.load(.acquire)) return;
            self.io.sleep(.fromMilliseconds(STEP_MS), .awake) catch return;
        }

        if (self.done.load(.acquire)) return;

        // Ends the pending read the way a closed connection does. Errors are
        // ignored: the socket may already have closed under us, which is the
        // case this is racing and the harmless outcome.
        self.stream.shutdown(self.io, .both) catch {};
    }
};

/// Connect, but give up after CONNECT_TIMEOUT_MS.
///
/// The watchdog cannot do this job: it works by shutting a socket down, and
/// during a connect there is no socket it can reach - `connectTcpOptions`
/// creates one internally and returns only once it is up. Against an
/// address that swallows SYNs that is however long the kernel retries,
/// which on Linux is a little over two minutes. Measured: still blocked at
/// 40s, where ten of the twelve ports gave up at 10.
///
/// So the connect is raced against a sleep, and the loser is cancelled.
/// `Io.Threaded` signals a thread that is blocked in a cancelable syscall,
/// so the cancel really does unblock a stuck connect rather than waiting
/// for it - measured cutting at the deadline to the millisecond.
///
/// A connect that lands in the same instant as the deadline is the case to
/// get right: its connection is already in the client's pool, marked used,
/// and `Client.deinit` ASSERTS that pool is empty. Dropping it would turn a
/// slow vault into a panic, which is the same trade this port already
/// refused once (see the note at the connect site). So the cancel is
/// drained and anything it hands back is closed.
fn dial(
    client: *std.http.Client,
    io: std.Io,
    host: std.Io.net.HostName,
    port: u16,
    protocol: std.http.Client.Protocol,
) !*std.http.Client.Connection {
    const Race = union(enum) {
        reached: std.http.Client.ConnectTcpError!*std.http.Client.Connection,
        expired: void,
    };

    const task = struct {
        fn connect(
            c: *std.http.Client,
            h: std.Io.net.HostName,
            p: u16,
            proto: std.http.Client.Protocol,
        ) std.http.Client.ConnectTcpError!*std.http.Client.Connection {
            return c.connectTcpOptions(.{ .host = h, .port = p, .protocol = proto });
        }

        fn countdown(i: std.Io) void {
            i.sleep(.fromMilliseconds(CONNECT_TIMEOUT_MS), .awake) catch {};
        }
    };

    const direct: std.http.Client.ConnectTcpOptions =
        .{ .host = host, .port = port, .protocol = protocol };

    var slots: [2]Race = undefined;
    var race: std.Io.Select(Race) = .init(io, &slots);

    // No spare unit of concurrency to race with. Connecting unbounded is
    // worse than connecting bounded and better than not connecting, so the
    // bound is what gets dropped.
    race.concurrent(.reached, task.connect, .{ client, host, port, protocol }) catch
        return client.connectTcpOptions(direct);

    // The connect is already running and must be awaited either way, so
    // from here every path goes through the select.
    race.concurrent(.expired, task.countdown, .{io}) catch {};

    // Cancel whatever is left, closing a connection that arrived too late
    // rather than leaving it in the pool for `Client.deinit` to assert on.
    // Draining in a loop is what the Select contract asks of a task that
    // allocates, and the connect is one.
    const drain = struct {
        fn all(r: *std.Io.Select(Race), c: *std.http.Client, i: std.Io) void {
            while (r.cancel()) |late| switch (late) {
                .reached => |result| if (result) |connection| {
                    connection.closing = true;
                    c.connection_pool.release(connection, i);
                } else |_| {},
                .expired => {},
            };
        }
    };

    const first = race.await() catch {
        drain.all(&race, client, io);
        return error.Canceled;
    };

    switch (first) {
        .reached => |result| {
            // Only the countdown is left, and it holds nothing.
            race.cancelDiscard();
            return result;
        },
        .expired => {
            drain.all(&race, client, io);
            return error.ConnectTimeout;
        },
    }
}

/// What one round-trip returns. `body` is null when the response carried no
/// JSON - only possible for a non-200, which is decided on status alone.
pub const Response = struct {
    status: u16,
    body: ?std.json.Value,
};

/// The result of a round-trip, or the message of a failure.
pub const Result = union(enum) {
    ok: Response,
    err: []const u8,
};

/// The part of a URL a failure message may show. A query string can carry a
/// vault path or a filter, so messages name the URL without it.
pub fn nakedurl(url: []const u8) []const u8 {
    const cut = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return url[0..cut];
}

/// One JSON round-trip.
pub fn fetchjson(
    alloc: Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    headers: []const Header,
    body: ?[]const u8,
) Allocator.Error!Result {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch {
        return .{ .err = try std.fmt.allocPrint(
            alloc,
            "sekreto: cannot reach {s}: not a valid url",
            .{nakedurl(url)},
        ) };
    };

    var text: std.Io.Writer.Allocating = .init(alloc);

    const status = roundtrip(&client, io, method, uri, headers, body, &text) catch |err| {
        // An endless body has its own message: "cannot reach" would be
        // wrong, since the store was reached and answered - just not with
        // anything this library will hold in memory.
        if (error.OversizedResponse == err) {
            return .{ .err = try std.fmt.allocPrint(
                alloc,
                "sekreto: oversized response from {s}",
                .{nakedurl(url)},
            ) };
        }

        return .{ .err = try std.fmt.allocPrint(
            alloc,
            "sekreto: cannot reach {s}: {s}",
            .{ nakedurl(url), @errorName(err) },
        ) };
    };

    const raw = text.writer.buffered();

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch {
        // A success status promised JSON; a body that does not parse means
        // the store could not answer coherently.
        if (200 == status) {
            return .{ .err = try std.fmt.allocPrint(
                alloc,
                "sekreto: malformed response from {s}",
                .{nakedurl(url)},
            ) };
        }
        return .{ .ok = .{ .status = status, .body = null } };
    };

    return .{ .ok = .{ .status = status, .body = parsed.value } };
}

// The request itself. Separated so that every way it can fail collapses
// into one "cannot reach" message, the way `fetch`'s error union would.
fn roundtrip(
    client: *std.http.Client,
    io: std.Io,
    method: std.http.Method,
    uri: std.Uri,
    headers: []const Header,
    body: ?[]const u8,
    text: *std.Io.Writer.Allocating,
) !u16 {
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedScheme;
    const port = uri.port orelse @as(u16, if (.tls == protocol) 443 else 80);

    var hostbuf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&hostbuf);

    if (.tls == protocol) {
        // std.http.Client scans the system trust store inside `request`, but
        // ONLY on the path where it opens the connection itself. This
        // request pre-connects - the one place std lets a timeout in - so
        // the handshake would otherwise read an unset trust store and
        // crash. Loading it here is what makes https work at all, which is
        // in turn why this port needs no TLS dependency.
        const now = std.Io.Clock.real.now(io);
        client.ca_bundle.rescan(client.allocator, io, now) catch
            return error.CertificateBundleLoadFailure;
        client.now = now;
    }

    const connection = try dial(client, io, host, port, protocol);

    // The bound std would not apply, for the rest of the request. See
    // CONNECT_TIMEOUT_MS: the `timeout` field on ConnectTcpOptions is
    // declared and never read, so this port had none at all; `dial` above
    // covers the connect, and this covers everything after it.
    //
    // Enforced with a watchdog rather than SO_RCVTIMEO. The socket option
    // is the obvious move and it is wrong here: it makes recv return EAGAIN,
    // and `Io.Threaded` treats EAGAIN on a socket read as a programmer bug
    // and PANICS. That turns a hung vault into a crash, which is not an
    // improvement. Shutting the socket down instead makes the pending read
    // end the way a closed connection does, which the reader already
    // handles, so a wedged vault surfaces as the ordinary "cannot reach"
    // error every other port gives.
    var watch: Watchdog = .{
        .stream = connection.stream_reader.stream,
        .io = io,
    };
    const watcher = std.Thread.spawn(.{}, Watchdog.run, .{&watch}) catch null;
    defer if (watcher) |thread| {
        watch.done.store(true, .release);
        thread.join();
    };

    var req = try client.request(method, uri, .{
        .connection = connection,
        .keep_alive = false,
        // Never follow a redirect: see the note at the top of this file.
        .redirect_behavior = .unhandled,
        .extra_headers = headers,
    });
    defer req.deinit();

    if (body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var writer = try req.sendBodyUnflushed(&.{});
        try writer.writer.writeAll(payload);
        try writer.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var response = try req.receiveHead(&.{});

    var transfer: [1024]u8 = undefined;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;

    // The client advertises gzip and deflate, so a server is entitled to
    // use them; decoding is not optional.
    const reader = response.readerDecompressing(&transfer, &decompress, &window);

    // Bounded, not streamRemaining: an endless body would otherwise be
    // accumulated until the watchdog fires, and a decompressing reader turns
    // a small one into a large one. An endless body is a store that could
    // not answer, so this is an error, never a miss.
    var total: u64 = 0;
    while (true) {
        const got = reader.stream(&text.writer, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return response.bodyErr().?,
            else => |rest| return rest,
        };

        total += got;
        if (MAXBODY < total) {
            return error.OversizedResponse;
        }
    }

    return @intFromEnum(response.head.status);
}

/// A map field of a JSON body, or null when anything on the way is absent
/// or not a map. The vault protocols nest their answers, and a chain of
/// `orelse return null` at every level is the same check written ten times.
pub fn jget(value: ?std.json.Value, key: []const u8) ?std.json.Value {
    const entry = value orelse return null;
    return switch (entry) {
        .object => |map| map.get(key),
        else => null,
    };
}

/// A JSON string field, or null when it is absent or not a string.
pub fn jstr(value: ?std.json.Value) ?[]const u8 {
    const entry = value orelse return null;
    return switch (entry) {
        .string => |found| found,
        else => null,
    };
}

/// A JSON number field as an integer, whatever shape it arrived in. Lease
/// and expiry durations are the only numbers these protocols carry, and
/// servers disagree about whether they are integers or strings.
pub fn jnum(value: ?std.json.Value) ?i64 {
    const entry = value orelse return null;
    return switch (entry) {
        .integer => |found| found,
        .float => |found| @intFromFloat(found),
        .number_string, .string => |found| std.fmt.parseInt(i64, found, 10) catch null,
        else => null,
    };
}

// ---- the helpers a plugin shares -------------------------------------

/// A base URL with one trailing slash removed, so paths join cleanly.
pub fn trimslash(addr: []const u8) []const u8 {
    if (0 != addr.len and '/' == addr[addr.len - 1]) {
        return addr[0 .. addr.len - 1];
    }
    return addr;
}

/// The configured value, or the first non-empty of the named environment
/// variables. Those names are the ecosystem's own convention, so a pod or a
/// CI job that already has them set should just work.
pub fn firstof(config: sekreto.Config, given: []const u8, names: []const []const u8) []const u8 {
    if (0 != given.len) {
        return given;
    }

    for (names) |name| {
        if (config.env.get(name)) |value| {
            if (0 != value.len) {
                return value;
            }
        }
    }

    return "";
}

/// Now, in milliseconds since the epoch. Token expiry is the only clock
/// this library reads.
pub fn nowms(io: std.Io) i64 {
    const stamp = std.Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(stamp.nanoseconds, std.time.ns_per_ms));
}

/// Never: a configured token is kept for the life of the process.
pub const NEVER: i64 = std.math.maxInt(i64);

/// When a lease of `seconds` should be renewed - a minute early, because a
/// long-running process must not keep presenting a token the vault already
/// expired.
pub fn renewafter(io: std.Io, seconds: ?i64) i64 {
    const lease = seconds orelse return NEVER;
    if (0 >= lease) {
        return NEVER;
    }
    return nowms(io) + 1000 * @max(lease - 60, 1);
}

/// Percent-escape one query-string value.
pub fn escape(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    for (text) |ch| {
        const plain = ('A' <= ch and 'Z' >= ch) or ('a' <= ch and 'z' >= ch) or
            ('0' <= ch and '9' >= ch) or '-' == ch or '_' == ch or '.' == ch or '~' == ch;

        if (plain) {
            try out.append(alloc, ch);
        } else {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "%{X:0>2}", .{ch}));
        }
    }

    return out.items;
}

/// One JSON string literal. The bodies this library sends are flat maps of
/// strings, so a full writer would be more machinery than the job needs.
pub fn jsonstring(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '"');

    for (text) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (0x20 > ch) {
                    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{ch}));
                } else {
                    try out.append(alloc, ch);
                }
            },
        }
    }

    try out.append(alloc, '"');
    return out.items;
}

/// A flat JSON object of string fields.
pub fn jsonobject(alloc: Allocator, fields: []const sekreto.KeyValue) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '{');

    for (fields, 0..) |field, at| {
        if (0 < at) {
            try out.append(alloc, ',');
        }
        try out.appendSlice(alloc, try jsonstring(alloc, field.key));
        try out.append(alloc, ':');
        try out.appendSlice(alloc, try jsonstring(alloc, field.value));
    }

    try out.append(alloc, '}');
    return out.items;
}
