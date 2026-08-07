
function preparePath(ctx) {
  const join = ctx.utility.struct.join
  const point = ctx.point

  const path = join(point.parts, '/', true)

  return path
}

module.exports = {
  preparePath
}
