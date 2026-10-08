# Univec SDK utility: prepare_body
require_relative 'media'
module UnivecUtilities
  PrepareBody = ->(ctx) {
    return nil unless ctx.op.input == "data"
    return UnivecUtilities.raw_body(ctx.reqdata) if UnivecUtilities.raw_request?(ctx.point)
    ctx.utility.transform_request.call(ctx)
  }
end
