// EJECT-START

  SdkEntityPtr remove(const Value& reqmatch, const Value& ctrl) override {
    CtxSpec cs;
    cs.setOpname("remove");
    cs.ctrlMap = ctrl.is_map() ? ctrl : vmap();
    cs.match = this->match_;
    cs.data = this->data_;
    cs.reqmatch = reqmatch.is_map() ? reqmatch : vmap();
    CtxPtr ctx = this->utility->makeContext(cs, this->entctx);

    runOp(ctx, [this, ctx]() {
      if (ctx->result) {
        if (ctx->result->resmatch.is_map()) {
          this->match_ = ctx->result->resmatch;
        }
      }
    });

    // The operation resolves to THIS entity: runOp has just absorbed the
    // result into it, and the caller reaches the record through data().
    // See AGENTS.md "Entity operations return ENTITIES".

    // A removed entity keeps its data but is no longer a live record.
    this->markDeleted();

    return this->self();
  }

// EJECT-END
