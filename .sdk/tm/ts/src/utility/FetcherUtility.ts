
import { Context, Response } from '../types'


// Several CDNs refuse a library's own agent, so outside a browser a request
// without one carries the browser-shaped agent most other targets send.
const DEFAULT_USER_AGENT = 'Mozilla/5.0 (compatible; UnivecSDK/1.0)'


function defaultUserAgent(fetchdef: Record<string, any>) {
  if (null == (globalThis as any).process?.versions?.node) {
    return
  }
  const headers = fetchdef.headers = fetchdef.headers || {}
  for (const name of Object.keys(headers)) {
    if ('user-agent' === name.toLowerCase()) {
      return
    }
  }
  headers['user-agent'] = DEFAULT_USER_AGENT
}


// Make HTTP call using library. Replace this utility for mocking etc.
async function fetcher(
  ctx: Context,
  fullurl: string,
  fetchdef: Record<string, any>
): Promise<Response | Error> {

  if ('live' !== ctx.client._mode) {
    return ctx.error('fetch_mode_block', 'Request blocked by mode: "' + ctx.client._mode +
      '" (URL was: "' + fullurl + '")')
  }

  const options = ctx.client.options()

  const getpath = ctx.utility.struct.getpath

  if (true === getpath(options, 'feature.test.active')) {
    return ctx.error('fetch_test_block', 'Request blocked as test feature is active' +
      ' (URL was: "' + fullurl + '")')
  }

  const fetch = options.system.fetch

  defaultUserAgent(fetchdef)

  const response = await fetch(fullurl, fetchdef)

  return response
}


export {
  fetcher,
  DEFAULT_USER_AGENT,
}
