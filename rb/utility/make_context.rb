# Univec SDK utility: make_context
require_relative '../core/context'
module UnivecUtilities
  MakeContext = ->(ctxmap, basectx) {
    UnivecContext.new(ctxmap, basectx)
  }
end
