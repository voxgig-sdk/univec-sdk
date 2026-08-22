// Convert entity client (generated). Shared entity runtime (data/match
// state, entity context, the runOp pipeline + feature hooks) lives in
// EntityBase (core/types.hpp); this class binds the entity name and its
// supported CRUD operations.

#pragma once

#include <memory>

#include "../core/types.hpp"

namespace sdk {

class ConvertEntity : public EntityBase {
public:
  ConvertEntity(SdkClient* client, Value entopts = Value::undef())
      : EntityBase("convert", client, entopts) {}

  EntityPtr make() override {
    Value opts = vmap();
    if (this->entopts.is_map()) {
      for (const auto& kv : *this->entopts.as_map()) {
        map_put(opts, kv.first, kv.second);
      }
    }
    return std::make_shared<ConvertEntity>(this->client, opts);
  }

  SdkEntityPtr load(const Value& reqmatch, const Value& ctrl) override {
      (void)reqmatch; (void)ctrl;
      throw Helpers::unsupportedOp("load", this->name_);
    }

  std::vector<SdkEntityPtr> list(const Value& reqmatch, const Value& ctrl) override {
      (void)reqmatch; (void)ctrl;
      throw Helpers::unsupportedOp("list", this->name_);
    }


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
  

  SdkEntityPtr update(const Value& reqdata, const Value& ctrl) override {
      (void)reqdata; (void)ctrl;
      throw Helpers::unsupportedOp("update", this->name_);
    }

  SdkEntityPtr remove(const Value& reqmatch, const Value& ctrl) override {
      (void)reqmatch; (void)ctrl;
      throw Helpers::unsupportedOp("remove", this->name_);
    }
};

} // namespace sdk
