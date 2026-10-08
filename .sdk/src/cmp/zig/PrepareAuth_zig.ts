
import {
  Content,
  File,
  cmp,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
  resolveAuthPrefix,
} from '@voxgig/sdkgen'


import {
  KIT,
  getModelPath,
} from '@voxgig/apidef'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { target } = props
  const { model } = props.ctx$

  const active = isAuthActive_zig(model)
  const where = resolveAuthIn(model)
  const name = resolveAuthName(model)
  const prefix = resolveAuthPrefix(model)
  const basic = isHttpBasicAuth(model)

  File({ name: 'prepare_auth.' + target.ext }, () => {
    Content(render({ active, where, name, prefix, basic }))
  })
})


type AuthSpec = {
  active: boolean
  where: string
  name: string
  prefix: string
  basic: boolean
}


const HEAD = `// prepare_auth — GENERATED from the model (src/cmp/zig/PrepareAuth_zig.ts),
// not copied from tm/zig, because WHERE THE CREDENTIAL GOES IS A FACT ABOUT
// THIS API. apidef resolves the security scheme's \`in\` and \`name\` into
// main.kit.info.security; a template can hold only one answer, and the one it
// held was an \`authorization\` header, so an apiKey-in-query API was sent a
// header it does not read and never sent the query parameter it does.
//
// This function used to live in core/utility.zig. It is re-exported from
// there (\`pub const prepare_auth_util = @import("prepare_auth.zig")...\`), so
// Utility.prepare_auth, make_spec_util and sdk.utilmod.prepare_auth_util all
// still reach the same symbol.
`


function render(spec: AuthSpec): string {
  if (!spec.active) return renderInactive()

  if ('query' === spec.where) return renderQuery(spec)
  if ('cookie' === spec.where) return renderCookie(spec)

  return renderHeader(spec)
}


function renderInactive(): string {
  return HEAD + `//
// THIS SDK SENDS NO CREDENTIAL: the project set
// \`main.kit.config.auth.active: false\`, which is the documented, explicit
// way to say so. The function stays in the pipeline because make_spec calls
// it unconditionally.

const h = @import("helpers.zig");
const ctxmod = @import("context.zig");
const spec_mod = @import("spec.zig");

const Context = ctxmod.Context;
const Spec = spec_mod.Spec;
const E = h.E;
` + facts('header', false, false) + `
pub fn prepare_auth_util(ctx: *Context) E!*Spec {
    const spec = ctx.spec orelse return ctx.fail("auth_no_spec", "Expected context spec property to be defined.");
    return spec;
}
`
}


function renderHeader(spec: AuthSpec): string {
  const withBasic = spec.basic

  return HEAD + imports({ vs: true, fmt: true }) +
    facts(spec.where, withBasic, true) + `
const CRED_NAME = ${zigstr(credLiteral(spec.where, spec.name))};
const OPTION_APIKEY = "apikey";
` + (withBasic ? `const OPTION_SECRET = "secret";
` : '') + `const NOT_FOUND = "__NOTFOUND__";
` + authName(true) + (withBasic ? basicHelpers() : '') + `
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
` + (withBasic ? basicBlock() : '') + `
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
`
}


function renderQuery(spec: AuthSpec): string {
  return HEAD + imports({ vs: true, fmt: false }) +
    facts(spec.where, false, true) + `
const CRED_NAME = ${zigstr(credLiteral(spec.where, spec.name))};
const OPTION_APIKEY = "apikey";
const NOT_FOUND = "__NOTFOUND__";
` + authName(false) + `
pub fn prepare_auth_util(ctx: *Context) E!*Spec {
    const spec = ctx.spec orelse return ctx.fail("auth_no_spec", "Expected context spec property to be defined.");

    const query = spec.query;
    const options: Value = if (ctx.client) |client| client.options_map() else ctx.options;

    // Public APIs that need no auth omit the options.auth block entirely.
    const auth = h.getp(options, "auth");
    if (h.is_noval(auth)) {
        h.del_prop(query, h.vstr(CRED_NAME));
        return spec;
    }

    const name = auth_name(options);

    // A credential left under the declared name would travel beside the renamed one.
    if (!std.mem.eql(u8, name, CRED_NAME)) {
        h.del_prop(query, h.vstr(CRED_NAME));
    }

    const apikey = vs.getprop(h.A(), options, h.vstr(OPTION_APIKEY), h.vstr(NOT_FOUND)) catch h.vstr(NOT_FOUND);

    const skip = switch (apikey) {
        .null => true,
        .string => |s| std.mem.eql(u8, s, NOT_FOUND) or s.len == 0,
        else => false,
    };

    if (skip) {
        h.del_prop(query, h.vstr(name));
    } else {
        const apikey_val: []const u8 = switch (apikey) {
            .string => |s| s,
            else => "",
        };
        // NO PREFIX IN A QUERY STRING. \`?${spec.name}=Bearer%20abc\` is not a
        // thing any API reads: the prefix is a header convention, so it is
        // dropped here deliberately rather than silently concatenated. Nor is
        // there an HTTP Basic branch - \`Authorization: Basic base64(u:p)\`
        // cannot be a query parameter.
        h.setp(query, name, h.vstr(apikey_val));
    }

    return spec;
}
`
}


// COOKIE — a cookie IS a header, so the credential rides the header bag; but
// the `cookie` header is SHARED with whatever cookies the caller set, so the
// pair is spliced in and out rather than assigned over. Splicing is also what
// makes this idempotent: a retried request cannot carry the credential twice.
function renderCookie(spec: AuthSpec): string {
  return HEAD + imports({ vs: true, fmt: true }) +
    facts(spec.where, false, true) + `
const COOKIE_HEADER = "cookie";
const CRED_NAME = ${zigstr(credLiteral(spec.where, spec.name))};
const OPTION_APIKEY = "apikey";
const NOT_FOUND = "__NOTFOUND__";
` + authName(false) + `
// The cookie header minus the named pair, every other cookie left alone.
fn cookies_without_cred(headers: Value, name: []const u8) []const u8 {
    const existing: []const u8 = switch (h.getp(headers, COOKIE_HEADER)) {
        .string => |s| s,
        else => "",
    };
    if (existing.len == 0) return "";

    return std.mem.join(h.A(), "; ", h.cookie_keep(existing, &[_][]const u8{name})) catch "";
}

// Set (a value) or remove (null) the named pair, leaving every other cookie in place.
fn apply_cookie(headers: Value, name: []const u8, value: ?[]const u8) void {
    const rest = cookies_without_cred(headers, name);

    if (value) |v| {
        // NO PREFIX IN A COOKIE either - a cookie carries a bare \`name=value\`
        // pair, not a header's scheme-prefixed credential.
        const pair = fmt("{s}={s}", .{ name, v });
        h.setp(headers, COOKIE_HEADER, h.vstr(if (rest.len == 0) pair else fmt("{s}; {s}", .{ rest, pair })));
        return;
    }

    if (rest.len == 0) {
        h.del_prop(headers, h.vstr(COOKIE_HEADER));
    } else {
        h.setp(headers, COOKIE_HEADER, h.vstr(rest));
    }
}

pub fn prepare_auth_util(ctx: *Context) E!*Spec {
    const spec = ctx.spec orelse return ctx.fail("auth_no_spec", "Expected context spec property to be defined.");

    const headers = spec.headers;
    const options: Value = if (ctx.client) |client| client.options_map() else ctx.options;

    // Public APIs that need no auth omit the options.auth block entirely.
    const auth = h.getp(options, "auth");
    if (h.is_noval(auth)) {
        apply_cookie(headers, CRED_NAME, null);
        return spec;
    }

    const name = auth_name(options);

    // A credential left under the declared name would travel beside the renamed one.
    if (!std.mem.eql(u8, name, CRED_NAME)) {
        apply_cookie(headers, CRED_NAME, null);
    }

    const apikey = vs.getprop(h.A(), options, h.vstr(OPTION_APIKEY), h.vstr(NOT_FOUND)) catch h.vstr(NOT_FOUND);

    const skip = switch (apikey) {
        .null => true,
        .string => |s| std.mem.eql(u8, s, NOT_FOUND) or s.len == 0,
        else => false,
    };

    if (skip) {
        apply_cookie(headers, name, null);
    } else {
        const apikey_val: []const u8 = switch (apikey) {
            .string => |s| s,
            else => "",
        };
        apply_cookie(headers, name, apikey_val);
    }

    return spec;
}
`
}


// The client's `auth.name` option, when set, replaces the declared name; a
// header name travels lower-cased.
function authName(header: boolean): string {
  return `
// The client's auth.name option, when set, replaces the name the API declares.
fn auth_name(options: Value) []const u8 {
    return switch (h.getpath(&.{ "auth", "name" }, options)) {
        .string => |s| if (s.len == 0) CRED_NAME else ${header ? 'std.ascii.allocLowerString(h.A(), s) catch CRED_NAME' : 's'},
        else => CRED_NAME,
    };
}
`
}


function imports(need: { vs: boolean, fmt: boolean }): string {
  return `
const std = @import("std");
` + (need.vs ? `const vs = @import("voxgig-struct");
` : '') + `const h = @import("helpers.zig");
const ctxmod = @import("context.zig");
const spec_mod = @import("spec.zig");

const Value = h.Value;
const Context = ctxmod.Context;
const Spec = spec_mod.Spec;
const E = h.E;
` + (need.fmt ? `
fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(h.A(), f, args) catch "";
}
` : '')
}


function basicHelpers(): string {
  return `
// Boolean-or-absent: an option that is unset, null or a non-boolean is false
// (core/utility.zig's is_true, which this file can no longer see).
fn is_true(v: Value) bool {
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

// Standard base64, arena-allocated - the encoding peer of sekreto's unbase64.
fn base64_std(text: []const u8) []const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = h.A().alloc(u8, enc.calcSize(text.len)) catch return "";
    return enc.encode(buf, text);
}
`
}


// HTTP Basic is header-only BY DEFINITION: the scheme is
// `Authorization: Basic base64(user:pass)`. It cannot be expressed as a query
// parameter or a cookie, so this branch is emitted only where it can mean
// something — and only when the model says the scheme IS basic.
function basicBlock(): string {
  return `
    // True HTTP Basic Auth joins the two credentials, base64-encoded - a single
    // token in the header (the branch below) can never authenticate against
    // an API that actually checks \`Authorization: Basic base64(user:pass)\`.
    // The password may be empty (RFC 7617): Lob, for one, documents the key as
    // the user with a blank password (\`curl -u key:\`).
    if (is_true(h.getpath(&.{ "auth", "basic" }, options))) {
        const secret = vs.getprop(h.A(), options, h.vstr(OPTION_SECRET), h.vstr(NOT_FOUND)) catch h.vstr(NOT_FOUND);

        const no_secret = switch (secret) {
            .null => true,
            .string => |s| std.mem.eql(u8, s, NOT_FOUND) or s.len == 0,
            else => false,
        };

        if (skip) {
            h.del_prop(headers, h.vstr(name));
        } else {
            const basic_prefix: []const u8 = switch (h.getpath(&.{ "auth", "prefix" }, options)) {
                .string => |s| s,
                else => "",
            };
            const apikey_val: []const u8 = switch (apikey) {
                .string => |s| s,
                else => "",
            };
            const secret_val: []const u8 = if (no_secret) "" else switch (secret) {
                .string => |s| s,
                else => "",
            };
            const b64 = base64_std(fmt("{s}:{s}", .{ apikey_val, secret_val }));
            // The joined, encoded pair is a wire form neither credential's own
            // registration covers.
            ctx.util().clean_add(ctx, b64);
            if (basic_prefix.len == 0) {
                h.setp(headers, name, h.vstr(b64));
            } else {
                h.setp(headers, name, h.vstr(fmt("{s} {s}", .{ basic_prefix, b64 })));
            }
        }

        return spec;
    }
`
}


function credLiteral(where: string, name: string): string {
  return 'header' === where ? String(name).toLowerCase() : String(name)
}


function isAuthActive_zig(model: any): boolean {
  const auth = getModelPath(model, `main.${KIT}.config.auth`,
    { only_active: false, required: false })
  return !(null != auth && false === auth.active)
}


function facts(where: string, basic: boolean, active: boolean): string {
  const placement = active ? where : 'none'

  return `
/// WHERE this SDK places its credential: "header", "query", "cookie", or
/// "none" when the project set \`main.kit.config.auth.active: false\`.
pub const PLACEMENT = ${zigstr(placement)};

/// True when the scheme is genuine HTTP Basic - two credentials, base64-joined
/// - rather than a single token. Header-only by definition, so false for every
/// other placement.
pub const BASIC = ${(basic && 'header' === where && active) ? 'true' : 'false'};
`
}


function zigstr(s: string): string {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'
}


export {
  PrepareAuth
}
