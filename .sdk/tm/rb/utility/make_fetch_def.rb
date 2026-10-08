# Univec SDK utility: make_fetch_def
require_relative 'media'
require_relative '../core/result'
module UnivecUtilities
  MakeFetchDef = ->(ctx) {
    spec = ctx.spec
    return nil, ctx.make_error("fetchdef_no_spec", "Expected context spec property to be defined.") unless spec

    ctx.result = UnivecResult.new({}) unless ctx.result
    spec.step = "prepare"

    url, err = ctx.utility.make_url.call(ctx)
    return nil, err if err

    spec.url = url

    fetchdef = { "url" => url, "method" => spec.method, "headers" => spec.headers }
    fetchdef["body"] = UnivecUtilities.request_body(ctx.point, spec.body) unless spec.body.nil?

    return fetchdef, nil
  }
end
