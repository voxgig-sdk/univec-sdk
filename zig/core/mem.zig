// Process-global arena allocator for the SDK data model.
//
// The SDK data model is the vendored voxgig struct Value (reference-stable
// *MapRef / *ListRef nodes). Rust leans on a global allocator + Rc; Zig has
// neither, so the whole SDK allocates from one process-lifetime arena. It is
// never freed during a run — the OS reclaims at exit — which keeps the port
// close to the Rust original and sidesteps the test allocator's leak checks
// for SDK/struct data (tests still use testing.allocator for their own
// bookkeeping). Mirrors struct/zig's per-run arena approach.

const std = @import("std");

var arena: ?std.heap.ArenaAllocator = null;

pub fn a() std.mem.Allocator {
    if (arena == null) {
        arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return arena.?.allocator();
}
