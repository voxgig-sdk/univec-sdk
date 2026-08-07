
function prepareMethod(ctx) {
  const op = ctx.op
  const opname = op.name

  let key = opname

  const methodMap = {
    create: 'POST',
    update: 'PUT',
    load: 'GET',
    list: 'GET',
    remove: 'DELETE',
    patch: 'PATCH',
  }

  return methodMap[key]
}

module.exports = {
  prepareMethod
}
