// prepare_auth — GENERATED from the model (src/cmp/zig/PrepareAuth_zig.ts),
// not copied from tm/zig, because WHERE THE CREDENTIAL GOES IS A FACT ABOUT
// THIS API. apidef resolves the security scheme's `in` and `name` into
// main.kit.info.security; a template can hold only one answer, and the one it
// held was an `authorization` header, so an apiKey-in-query API was sent a
// header it does not read and never sent the query parameter it does.
//
// This function used to live in core/utility.zig. It is re-exported from
// there (`pub const prepare_auth_util = @import("prepare_auth.zig")...`), so
// Utility.prepare_auth, make_spec_util and sdk.utilmod.prepare_auth_util all
// still reach the same symbol.

const std = @import("std");
const vs = @import("voxgig-struct");
const h = @import("helpers.zig");
const ctxmod = @import("context.zig");
const spec_mod = @import("spec.zig");

const Value = h.Value;
const Context = ctxmod.Context;
const Spec = spec_mod.Spec;
const E = h.E;

fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(h.A(), f, args) catch "";
}

/// WHERE this SDK places its credential: "header", "query", "cookie", or
/// "none" when the project set `main.kit.config.auth.active: false`.
pub const PLACEMENT = "header";

/// True when the scheme is genuine HTTP Basic - two credentials, base64-joined
/// - rather than a single token. Header-only by definition, so false for every
/// other placement.
pub const BASIC = false;

const CRED_NAME = "authorization";
const OPTION_APIKEY = "apikey";
const NOT_FOUND = "__NOTFOUND__";

// The client's auth.name option, when set, replaces the name the API declares.
fn auth_name(options: Value) []const u8 {
    return switch (h.getpath(&.{ "auth", "name" }, options)) {
        .string => |s| if (s.len == 0) CRED_NAME else std.ascii.allocLowerString(h.A(), s) catch CRED_NAME,
        else => CRED_NAME,
    };
}

pub fn prepare_auth_util(ctx: *Context) E!*Spec {
    const spec = ctx.spec orelse return ctx.fail("auth_no_spec", "Expected context spec property to be defined.");

    const headers = spec.headers;
    const options: Value = if (ctx.client) |client| client.options_map() else ctx.options;

    // Public APIs that need no auth omit the options.auth block entirely.
    const auth = h.getp(options, "auth");
    if (h.is_noval(auth)) {
        h.del_prop(headers, h.vstr(CRED_NAME));
        return spec;
    }

    const name = auth_name(options);

    // A credential left under the declared name would travel beside the renamed one.
    if (!std.mem.eql(u8, name, CRED_NAME)) {
        h.del_prop(headers, h.vstr(CRED_NAME));
    }

    const apikey = vs.getprop(h.A(), options, h.vstr(OPTION_APIKEY), h.vstr(NOT_FOUND)) catch h.vstr(NOT_FOUND);

    const skip = switch (apikey) {
        .null => true,
        .string => |s| std.mem.eql(u8, s, NOT_FOUND) or s.len == 0,
        else => false,
    };

    if (skip) {
        h.del_prop(headers, h.vstr(name));
    } else {
        const auth_prefix: []const u8 = switch (h.getpath(&.{ "auth", "prefix" }, options)) {
            .string => |s| s,
            else => "",
        };
        const apikey_val: []const u8 = switch (apikey) {
            .string => |s| s,
            else => "",
        };
        // A raw credential (empty prefix, e.g. an apiKey scheme) must go in
        // as-is; only a non-empty prefix (Bearer/Basic/OAuth) is space-joined.
        if (auth_prefix.len == 0) {
            h.setp(headers, name, h.vstr(apikey_val));
        } else {
            h.setp(headers, name, h.vstr(fmt("{s} {s}", .{ auth_prefix, apikey_val })));
        }
    }

    return spec;
}
