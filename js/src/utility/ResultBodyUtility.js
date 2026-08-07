
async function resultBody(ctx) {
  const response = ctx.response
  const result = ctx.result

  if (result) {
    if (response && response.json && null != response.body) {
      const json = await response.json()
      result.body = json
    }
  }

  return result
}

module.exports = {
  resultBody
}
