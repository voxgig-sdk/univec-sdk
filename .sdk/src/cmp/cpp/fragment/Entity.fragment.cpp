// EntityName entity client (generated). Shared entity runtime (data/match
// state, entity context, the runOp pipeline + feature hooks) lives in
// EntityBase (core/types.hpp); this class binds the entity name and its
// supported CRUD operations.

#pragma once

#include <memory>

#include "../core/types.hpp"

namespace sdk {

class EntyClass : public EntityBase {
public:
  EntyClass(SdkClient* client, Value entopts = Value::undef())
      : EntityBase("entityname", client, entopts) {}

  EntityPtr make() override {
    Value opts = vmap();
    if (this->entopts.is_map()) {
      for (const auto& kv : *this->entopts.as_map()) {
        map_put(opts, kv.first, kv.second);
      }
    }
    return std::make_shared<EntyClass>(this->client, opts);
  }

  // #LoadOp

  // #ListOp

  // #CreateOp

  // #UpdateOp

  // #RemoveOp
};

} // namespace sdk
