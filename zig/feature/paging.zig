// Pagination support for list operations (mirrors go feature/paging_feature.go
// / rust feature/paging.rs). On the way out (PreRequest) it stamps page/limit
// (or a cursor) into the request query; on the way back (PreResult) it reads
// the server's pagination signals — a `Link: rel="next"` header,
// `X-Page`/`X-Next-Page`/`X-Total-Count` headers, or
// `next`/`cursor`/`nextCursor`/`hasMore` fields in the body — and records them
// on `result.paging`. A per-call cursor/page from ctrl takes priority (used by
// auto-iteration). Parameter names (`pageParam`, `limitParam`, `cursorParam`),
// the page size (`limit`) and the start page (`startPage`, default 1) are
// configurable.

const std = @import("std");
const h = @import("../core/helpers.zig");
const types = @import("../core/types.zig");
const sup = @import("support.zig");

const Value = h.Value;
const Context = types.Context;
const Feature = types.Feature;

fn lowerAlloc(s: []const u8) []const u8 {
    const buf = h.A().alloc(u8, s.len) catch return s;
    return std.ascii.lowerString(buf, s);
}

// Extract the URL of the `rel="next"` entry from a Link header value.
fn link_next(link: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, link, ',');
    while (it.next()) |seg| {
        const lower = lowerAlloc(seg);
        if (std.mem.indexOf(u8, lower, "rel=\"next\"") != null or std.mem.indexOf(u8, lower, "rel=next") != null) {
            const open = std.mem.indexOfScalar(u8, seg, '<') orelse return null;
            const close = std.mem.indexOfScalar(u8, seg, '>') orelse return null;
            if (open < close) {
                return seg[open + 1 .. close];
            }
        }
    }
    return null;
}

fn header_num(headers: Value, name: []const u8, paging: Value, key: []const u8) void {
    const v = sup.fheader_get(headers, name) orelse return;
    switch (v) {
        .string => |s| {
            const n = sup.fparse_int(s, -1);
            if (n >= 0) h.setp(paging, key, h.vnum(n));
        },
        .integer => |n| h.setp(paging, key, h.vnum(n)),
        .float => |f| h.setp(paging, key, h.vfloat(f)),
        else => {},
    }
}

pub const PagingFeature = struct {
    name: []const u8 = "paging",
    active: bool = true,
    add_opts: Value = .{ .null = {} },
    options: Value = .{ .null = {} },

    // Activity tracking (mirrors the ts client._paging record).
    last: Value = .{ .null = {} },

    pub fn make() Feature {
        const self = h.A().create(PagingFeature) catch unreachable;
        self.* = .{};
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn self_of(p: *anyopaque) *PagingFeature {
        return @ptrCast(@alignCast(p));
    }

    fn is_list(self: *PagingFeature, ctx: *Context) bool {
        const opname = ctx.op.name;
        const ops: []const []const u8 = sup.fopt_str_list(self.options, "ops") orelse &[_][]const u8{"list"};
        for (ops) |o| {
            if (std.mem.eql(u8, o, opname)) return true;
        }
        return false;
    }

    fn pre_request(self: *PagingFeature, ctx: *Context) void {
        if (!self.active or !self.is_list(ctx)) return;
        const sp = ctx.spec orelse return;

        const query: Value = if (sp.query == .object) sp.query else blk: {
            const nq = h.omap();
            sp.query = nq;
            break :blk nq;
        };

        const page_param = sup.fopt_str(self.options, "pageParam", "page");
        const limit_param = sup.fopt_str(self.options, "limitParam", "limit");
        const cursor_param = sup.fopt_str(self.options, "cursorParam", "cursor");

        // A per-call cursor/page from ctrl takes priority (auto-iteration).
        const paging = ctx.ctrl.paging;

        // GraphQL paginates through operation VARIABLES, not the query
        // string. This hook runs after make_spec, so spec.body already holds
        // the { query, variables } envelope, and before make_fetch_def
        // serialises it.
        const kind: []const u8 = switch (h.getp(ctx.point, "kind")) {
            .string => |k| k,
            else => "",
        };
        if (std.mem.eql(u8, kind, "graphql")) {
            self.graphql_pre_request(ctx, paging);
            return;
        }

        const cursor = h.getp(paging, "cursor");
        if (!h.is_noval(cursor)) {
            h.setp(query, cursor_param, cursor);
        } else if (h.is_noval(h.getp(query, page_param))) {
            const page = h.getp(paging, "page");
            if (!h.is_noval(page)) {
                h.setp(query, page_param, page);
            } else {
                h.setp(query, page_param, h.vnum(sup.fopt_int(self.options, "startPage", 1)));
            }
        }

        if (!h.is_noval(h.getp(self.options, "limit")) and h.is_noval(h.getp(query, limit_param))) {
            h.setp(query, limit_param, h.vnum(sup.fopt_int(self.options, "limit", 0)));
        }
    }

    // Relay pagination: the cursor is the `after` variable (or whatever the
    // model named it), and the page size is `first`.
    fn graphql_pre_request(self: *PagingFeature, ctx: *Context, paging: Value) void {
        const sp = ctx.spec orelse return;
        if (sp.body != .object) return;

        const variables: Value = if (h.getp(sp.body, "variables") == .object)
            h.getp(sp.body, "variables")
        else blk: {
            const nv = h.omap();
            h.setp(sp.body, "variables", nv);
            break :blk nv;
        };

        const after_var = sup.fopt_str(self.options, "afterVar", "after");
        const first_var = sup.fopt_str(self.options, "firstVar", "first");

        // Only bind variables the operation actually declares, or the server
        // rejects the document.
        var after_declared = false;
        var first_declared = false;
        const varlist = h.getpath(&.{ "graphql", "vars" }, ctx.point);
        if (varlist == .array) {
            for (varlist.array.data.items) |v| {
                const name: []const u8 = switch (h.getp(v, "name")) {
                    .string => |n| n,
                    else => continue,
                };
                if (std.mem.eql(u8, name, after_var)) after_declared = true;
                if (std.mem.eql(u8, name, first_var)) first_declared = true;
            }
        }

        const cursor = h.getp(paging, "cursor");
        if (after_declared and !h.is_noval(cursor) and !h.is_null(cursor)) {
            h.setp(variables, after_var, cursor);
        }

        // `limit: null` reads as unset, matching the reference's `null !=
        // limit`: fopt_int would otherwise coerce it to 0 and bind `first: 0`,
        // which relay servers reject or answer with an empty page.
        const limit = h.getp(self.options, "limit");
        if (first_declared and !h.is_noval(limit) and !h.is_null(limit) and
            h.is_noval(h.getp(variables, first_var)))
        {
            h.setp(variables, first_var, h.vnum(sup.fopt_int(self.options, "limit", 0)));
        }
    }

    // The model records connection/cursor/more as dot paths; core getpath
    // takes pre-split segments.
    fn getpath_dotted(path: []const u8, store: Value) Value {
        // Segment count is bounded by dots + 1, so one pass sizes the slice
        // exactly. A fixed array would silently stop splitting and look up a
        // truncated path, which reads as "no cursor" — indistinguishable from
        // a genuine end of pagination. splitScalar yields slices into `path`,
        // so unlike the C port there is nothing to copy.
        var nseg: usize = 1;
        for (path) |c| {
            if (c == '.') nseg += 1;
        }

        const segs = h.A().alloc([]const u8, nseg) catch return h.vnull();

        var n: usize = 0;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            segs[n] = seg;
            n += 1;
        }

        return h.getpath(segs[0..n], store);
    }

    fn pre_result(self: *PagingFeature, ctx: *Context) void {
        if (!self.active or !self.is_list(ctx)) return;
        const result = ctx.result orelse return;

        const headers = result.headers;
        const body = result.body;

        const paging = h.omap();
        h.setp(paging, "hasMore", h.vbool(false));
        header_num(headers, "x-page", paging, "page");
        header_num(headers, "x-total-count", paging, "totalCount");
        header_num(headers, "x-next-page", paging, "nextPage");

        // Link: <...>; rel="next"
        if (sup.fheader_get(headers, "link")) |lv| {
            if (lv == .string) {
                if (link_next(lv.string)) |next| {
                    h.setp(paging, "next", h.vstr(next));
                }
            }
        }

        // Set when the response states hasMore outright, rather than leaving
        // it to be inferred from the presence of a cursor.
        var explicit_more = false;

        // Relay connections carry the cursor in pageInfo, at the path the
        // model recorded for this op.
        const page = h.getpath(&.{ "graphql", "page" }, ctx.point);
        if (page == .object and body == .object) {
            // `connpath` locates the connection object inside the response
            // envelope (data.<field>); the cursor/more paths are relative
            // to it.
            var conn = body;
            const connpath = h.get_str(page, "connpath") orelse "";
            if (connpath.len != 0) {
                const sub = getpath_dotted(connpath, body);
                if (!h.is_noval(sub) and !h.is_null(sub)) conn = sub;
            }

            const cursorpath = h.get_str(page, "cursor") orelse "";
            if (cursorpath.len != 0) {
                const c = getpath_dotted(cursorpath, conn);
                if (!h.is_noval(c) and !h.is_null(c)) h.setp(paging, "cursor", c);
            }

            const morepath = h.get_str(page, "more") orelse "";
            if (morepath.len != 0) {
                const mv = getpath_dotted(morepath, conn);
                if (mv == .bool) {
                    h.setp(paging, "hasMore", h.vbool(mv.bool));
                    explicit_more = true;
                }
            }
        }

        // Body-level cursors.
        if (body == .object) {
            const next = h.getp(body, "next");
            if (!h.is_noval(next) and h.is_noval(h.getp(paging, "next"))) {
                h.setp(paging, "next", next);
            }
            const cursor = h.getp(body, "cursor");
            if (!h.is_noval(cursor)) {
                h.setp(paging, "cursor", cursor);
            }
            const next_cursor = h.getp(body, "nextCursor");
            if (!h.is_noval(next_cursor)) {
                h.setp(paging, "cursor", next_cursor);
            }
            if (h.get_bool(body, "hasMore")) |has_more| {
                h.setp(paging, "hasMore", h.vbool(has_more));
                explicit_more = true;
            }
        }

        // Cursor presence only INFERS another page. When the server stated
        // the answer outright — relay's `hasNextPage: false`, or a body
        // `hasMore` — that wins: a final page normally carries both an end
        // cursor and hasNextPage false, and inferring from the cursor there
        // would send the caller back for a page that does not exist, forever.
        if (!explicit_more and (h.get_bool(paging, "hasMore") orelse false) != true and
            (!h.is_noval(h.getp(paging, "next")) or
            !h.is_noval(h.getp(paging, "cursor")) or
            !h.is_noval(h.getp(paging, "nextPage"))))
        {
            h.setp(paging, "hasMore", h.vbool(true));
        }

        result.paging = paging;
        self.last = paging;
    }

    fn vname(p: *anyopaque) []const u8 {
        return self_of(p).name;
    }
    fn vactive(p: *anyopaque) bool {
        return self_of(p).active;
    }
    fn vaddopts(p: *anyopaque) Value {
        return self_of(p).add_opts;
    }
    fn vinit(p: *anyopaque, ctx: *Context, options: Value) void {
        _ = ctx;
        const self = self_of(p);
        self.options = options;
        self.active = sup.fopt_bool(options, "active", false);
    }
    fn vdispatch(p: *anyopaque, name: []const u8, ctx: *Context) void {
        const self = self_of(p);
        if (std.mem.eql(u8, name, "PreRequest")) {
            self.pre_request(ctx);
        } else if (std.mem.eql(u8, name, "PreResult")) {
            self.pre_result(ctx);
        }
    }

    const vtable = Feature.VTable{
        .name = vname,
        .active = vactive,
        .add_options = vaddopts,
        .init = vinit,
        .dispatch = vdispatch,
    };
};
