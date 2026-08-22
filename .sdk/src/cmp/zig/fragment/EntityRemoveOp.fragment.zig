// EJECT-START

pub fn remove(self: *EntyClass, reqmatch: Value, ctrl: Value) EntResult {
    const ctx = self.utility.make_context(CtxSpec{
        .opname = "remove",
        .ctrl = ctrl,
        .mtch = self.mtch,
        .data = self.data,
        .reqmatch = reqmatch,
    }, self.ent_ctx());
    const res = self.run_op_ent(ctx, remove_post_done);
    // A removed entity keeps its data but is no longer a live record.
    if (res == .ok) self.mark_deleted();
    return res;
}

fn remove_post_done(self: *EntyClass, ctx: *Context) void {
    if (ctx.result) |result| {
        const resmatch = result.resmatch;
        const resdata = result.resdata;
        if (resmatch == .object) self.mtch = resmatch;
        if (!h.is_noval(resdata)) {
            const cm = h.to_map(h.clone(resdata));
            self.data = if (cm == .object) cm else h.omap();
        }
    }
}

// EJECT-END
