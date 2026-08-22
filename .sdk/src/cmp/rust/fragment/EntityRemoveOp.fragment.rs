// EJECT-START

fn remove(self: &Rc<Self>, reqmatch: Value, ctrl: Value) -> Result<Rc<Self>, ProjectNameError> {
    let ctx = self.utility.make_context(
        CtxSpec {
            opname: Some("remove".to_string()),
            ctrl: Some(ctrl),
            mtch: Some(self.mtch.borrow().clone()),
            data: Some(self.data.borrow().clone()),
            reqmatch: Some(reqmatch),
            ..Default::default()
        },
        Some(&self.ent_ctx()),
    );

    self.run_op(&ctx, &|ctx| {
        if let Some(result) = ctx.result.borrow().clone() {
            let (resmatch, resdata) = {
                let r = result.borrow();
                (r.resmatch.clone(), r.resdata.clone())
            };
            if let Value::Map(_) = resmatch {
                *self.mtch.borrow_mut() = resmatch;
            }
            if !resdata.is_noval() && !resdata.is_null() {
                *self.data.borrow_mut() = match to_map(&vs::clone(&resdata)) {
                    Value::Map(m) => Value::Map(m),
                    _ => Value::empty_map(),
                };
            }
        }
    })?;

    // The operation resolves to THIS entity: `run_op` has just absorbed the
    // result into it, and the caller reaches the record through `.data(None)`.
    // See AGENTS.md "Entity operations return ENTITIES". A removed entity
    // keeps its data but is no longer a live record.
    self.mark_deleted();

    Ok(self.clone())
}

// EJECT-END
