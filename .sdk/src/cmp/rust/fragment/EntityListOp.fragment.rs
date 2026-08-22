// EJECT-START

fn list(self: &Rc<Self>, reqmatch: Value, ctrl: Value) -> Result<Vec<Rc<Self>>, ProjectNameError> {
    let ctx = self.utility.make_context(
        CtxSpec {
            opname: Some("list".to_string()),
            ctrl: Some(ctrl),
            mtch: Some(self.mtch.borrow().clone()),
            data: Some(self.data.borrow().clone()),
            reqmatch: Some(reqmatch),
            ..Default::default()
        },
        Some(&self.ent_ctx()),
    );

    let out = self.run_op(&ctx, &|ctx| {
        if let Some(result) = ctx.result.borrow().clone() {
            let resmatch = result.borrow().resmatch.clone();
            if let Value::Map(_) = resmatch {
                *self.mtch.borrow_mut() = resmatch;
            }
        }
    })?;

    // `list` resolves to one ENTITY per record. makeResult cannot build them
    // here — it works in `Value`, which is a closed data union with no slot
    // for an entity — so the op does, mirroring what the dynamic targets get
    // from makeResult. See AGENTS.md "Entity operations return ENTITIES".
    let mut items: Vec<Rc<Self>> = Vec::new();
    if let Value::List(list) = &out {
        for entry in list.borrow().iter() {
            let ent = EntyClass::new(&self.client, vs::clone(&self.entopts));
            if let Value::Map(_) = entry {
                ent.data(Some(entry));
            }
            items.push(ent);
        }
    }

    Ok(items)
}

// EJECT-END
