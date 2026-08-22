// EJECT-START

pub fn list(self: *EntyClass, reqmatch: Value, ctrl: Value) EntListResult {
    const ctx = self.utility.make_context(CtxSpec{
        .opname = "list",
        .ctrl = ctrl,
        .mtch = self.mtch,
        .data = self.data,
        .reqmatch = reqmatch,
    }, self.ent_ctx());
    const out = switch (self.run_op(ctx, list_post_done)) {
        .err => |e| return EntListResult{ .err = e },
        .ok => |v| v,
    };

    // `list` resolves to one ENTITY per record. make_result cannot build them
    // here — it works in Value, which has no slot for an entity — so the op
    // does, mirroring what the dynamic targets get from make_result.
    var items = std.ArrayList(*EntyClass).init(h.A());
    if (out == .array) {
        for (out.array.data.items) |entry| {
            const ent = EntyClass.new(self.client, h.clone(self.entopts));
            if (entry == .object) {
                _ = ent.data_impl(entry);
            }
            items.append(ent) catch {};
        }
    }

    return EntListResult{ .ok = items.toOwnedSlice() catch &[_]*EntyClass{} };
}

fn list_post_done(self: *EntyClass, ctx: *Context) void {
    if (ctx.result) |result| {
        const resmatch = result.resmatch;
        if (resmatch == .object) self.mtch = resmatch;
    }
}

// EJECT-END
