
function featureInit(ctx, f) {
  const fopts = ctx.options.feature[f.name] || {}
  if (true === fopts.active) {
    f.init(ctx, fopts)
  }
}

module.exports = {
  featureInit
}
