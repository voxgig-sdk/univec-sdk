// make_context utility (mirrors utility/make_context.rs).

#include "sdk.h"

Context* make_context_util(CtxSpec spec, Context* basectx) {
  return context_new(spec, basectx);
}
