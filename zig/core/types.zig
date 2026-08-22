// Core interfaces and staged pipeline products (mirrors go core/types.go /
// the rust core/types.rs). Zig has no traits; features and entities are
// interface structs (a `*anyopaque` self + a const vtable of function
// pointers). The transport (`Fetcher`) is likewise a closure struct so
// features can wrap it while capturing state.

const std = @import("std");
const h = @import("helpers.zig");
const err = @import("error.zig");
const spec_mod = @import("spec.zig");
const resp_mod = @import("response.zig");
const result_mod = @import("result.zig");

const Value = h.Value;
pub const Context = @import("context.zig").Context;

// Feature: every pipeline hook, dispatched by name. `add_options` mirrors
// go's AddOptions so featureAdd __before__/__after__/__replace__ ordering
// works (returns .null when the feature declares no ordering).
pub const Feature = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (*anyopaque) []const u8,
        active: *const fn (*anyopaque) bool,
        add_options: *const fn (*anyopaque) Value,
        init: *const fn (*anyopaque, *Context, Value) void,
        dispatch: *const fn (*anyopaque, []const u8, *Context) void,
    };

    pub fn name(self: Feature) []const u8 {
        return self.vtable.name(self.ptr);
    }
    pub fn active(self: Feature) bool {
        return self.vtable.active(self.ptr);
    }
    pub fn add_options(self: Feature) Value {
        return self.vtable.add_options(self.ptr);
    }
    pub fn callInit(self: Feature, ctx: *Context, options: Value) void {
        self.vtable.init(self.ptr, ctx, options);
    }
    pub fn dispatch(self: Feature, hook: []const u8, ctx: *Context) void {
        self.vtable.dispatch(self.ptr, hook, ctx);
    }
};

// Entity: the dynamic entity contract. `matchv` is go's Match.
pub const Entity = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get_name: *const fn (*anyopaque) []const u8,
        make: *const fn (*anyopaque) Entity,
        data: *const fn (*anyopaque, ?Value) Value,
        matchv: *const fn (*anyopaque, ?Value) Value,
    };

    pub fn get_name(self: Entity) []const u8 {
        return self.vtable.get_name(self.ptr);
    }
    pub fn makeEnt(self: Entity) Entity {
        return self.vtable.make(self.ptr);
    }
    pub fn data(self: Entity, args: ?Value) Value {
        return self.vtable.data(self.ptr, args);
    }
    pub fn matchv(self: Entity, args: ?Value) Value {
        return self.vtable.matchv(self.ptr, args);
    }
};

// Transport: (ctx, url, fetchdef) -> transport-shaped response map, or an
// error via ctx.pending_err. A closure struct so retry/cache/netsim/proxy
// can wrap it in their init while capturing the inner transport + options.
pub const Fetcher = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, opctx: *Context, url: []const u8, fetchdef: Value) err.E!Value,

    pub fn invoke(self: Fetcher, opctx: *Context, url: []const u8, fetchdef: Value) err.E!Value {
        return self.call(self.ctx, opctx, url, fetchdef);
    }
};

// The public result of an operation: either data or the branded error.
// (Zig error unions cannot carry a payload, so the rich error travels here.)
pub const OpResult = union(enum) {
    ok: Value,
    err: *err.UnivecError,
};

// Pipeline stage products staged on ctx.out.
pub const OutVal = union(enum) {
    val: Value,
    err: *err.UnivecError,
    spec: *spec_mod.Spec,
    response: *resp_mod.Response,
    result: *result_mod.SdkResult,
};
