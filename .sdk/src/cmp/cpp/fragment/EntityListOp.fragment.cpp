// EJECT-START

  std::vector<SdkEntityPtr> list(const Value& reqmatch, const Value& ctrl) override {
    CtxSpec cs;
    cs.setOpname("list");
    cs.ctrlMap = ctrl.is_map() ? ctrl : vmap();
    cs.match = this->match_;
    cs.data = this->data_;
    cs.reqmatch = reqmatch.is_map() ? reqmatch : vmap();
    CtxPtr ctx = this->utility->makeContext(cs, this->entctx);

    Value out = runOp(ctx, [this, ctx]() {
      if (ctx->result) {
        if (ctx->result->resmatch.is_map()) {
          this->match_ = ctx->result->resmatch;
        }
      }
    });

    // `list` resolves to one ENTITY per record. makeResult cannot build them
    // here - it works in Value, which has no slot for an entity - so the op
    // does, mirroring what the dynamic targets get from makeResult.
    std::vector<SdkEntityPtr> items;
    if (out.is_list()) {
      for (const auto& entry : *out.as_list()) {
        SdkEntityPtr ent = std::static_pointer_cast<SdkEntity>(this->make());
        if (entry.is_map()) {
          ent->data(entry);
        }
        items.push_back(ent);
      }
    }

    return items;
  }

// EJECT-END
