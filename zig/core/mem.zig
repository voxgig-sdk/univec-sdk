// Process-global arena allocator and Io for the SDK data model.
//
// The SDK data model is the vendored voxgig struct Value (reference-stable
// *MapRef / *ListRef nodes). Rust leans on a global allocator + Rc; Zig has
// neither, so the whole SDK allocates from one process-lifetime arena. It is
// never freed during a run — the OS reclaims at exit — which keeps the port
// close to the Rust original and sidesteps the test allocator's leak checks
// for SDK/struct data (tests still use testing.allocator for their own
// bookkeeping). Mirrors struct/zig's per-run arena approach.
//
// Zig 0.16 routes clocks, sleeping, the environment and file IO through an
// `std.Io` instance rather than free functions on `std.time` / `std.process` /
// `std.fs`. An SDK cannot demand one from its caller without changing every
// public signature, so — exactly as with the arena — one process-global
// instance is used. `Io.Threaded.global_single_threaded` is the statically
// initialised singleton std itself falls back to; it needs no allocator and no
// deinit, and the startup code fills in its environment block.

const std = @import("std");

var arena: ?std.heap.ArenaAllocator = null;

pub fn a() std.mem.Allocator {
    if (arena == null) {
        arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return arena.?.allocator();
}

pub fn threaded() *std.Io.Threaded {
    return std.Io.Threaded.global_single_threaded;
}

pub fn io() std.Io {
    return threaded().io();
}
