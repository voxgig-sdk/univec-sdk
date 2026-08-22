// EJECT-START

  SdkEntityPtr create(const Value& reqdata, const Value& ctrl) override {
    CtxSpec cs;
    cs.setOpname("create");
    cs.ctrlMap = ctrl.is_map() ? ctrl : vmap();
    cs.match = this->match_;
    cs.data = this->data_;
    cs.reqdata = reqdata.is_map() ? reqdata : vmap();
    CtxPtr ctx = this->utility->makeContext(cs, this->entctx);

    runOp(ctx, [this, ctx]() {
      if (ctx->result) {
        if (!is_nullish(ctx->result->resdata)) {
          Value d = Helpers::toMapAny(Struct::clone(ctx->result->resdata));
          this->data_ = d.is_map() ? d : vmap();
        }
      }
    });

    // The operation resolves to THIS entity: runOp has just absorbed the
    // result into it, and the caller reaches the record through data().
    // See AGENTS.md "Entity operations return ENTITIES".

    return this->self();
  }

// EJECT-END
