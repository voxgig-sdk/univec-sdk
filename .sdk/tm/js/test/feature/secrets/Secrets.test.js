// Behavioural tests for the secrets feature (vendored @voxgig/sekreto).
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because SecretsFeature places it FIRST in the provider
// chain (a `memory` store named `options`) — explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic.
// With the feature inactive nothing changes at all. With it active and the
// option unset, the chain (env, dotenv, a custom provider, a vault)
// supplies the credential instead.
//
// This file lives in the `feature/` container on purpose: `target add`
// trims it, along with the feature source and the vendored library, for a
// project whose model does not select `secrets`.

const { test, describe, beforeEach } = require('node:test')
const assert = require('node:assert')

const { SDK } = require('../../utility/index')


const ENVPREFIX = 'PROJECTENV_TEST_SECRETS_'


// prepare() returns the fetchdef the transport would receive — the closest
// observable point to the wire for header assertions — and it awaits
// secrets resolution itself, because it bypasses the feature hook pipeline.
async function prepared(sdkopts) {
  const sdk = SDK.test({}, sdkopts)
  const fetchdef = await sdk.prepare({ path: '/' })
  assert.ok(!(fetchdef instanceof Error), String(fetchdef))
  return { sdk, fetchdef }
}


// The Authorization header carries the SPEC's credential prefix, which a
// TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
// `Bearer <token>`, an apiKey scheme the raw token. So assert on the
// CREDENTIAL and let the prefix be whatever this SDK's API declares —
// pinning the whole header value passes only for a prefix-less API, and
// this file ships to every project that selects the feature.
function credentialIs(header, token) {
  const got = String(null == header ? '' : header)
  assert.ok(got === token || got.endsWith(' ' + token),
    'expected the Authorization header to carry ' + token + ', got: ' + got)
}


// An env chain, the shape most of these tests use.
function envchain(extra) {
  return {
    feature: {
      secrets: Object.assign({
        active: true,
        providers: [{ kind: 'env', prefix: ENVPREFIX }],
      }, extra || {}),
    },
  }
}


describe('secrets', () => {

  beforeEach(() => {
    delete process.env[ENVPREFIX + 'APIKEY']
  })


  test('inactive: apikey option behaves exactly as before', async () => {
    const { sdk, fetchdef } = await prepared({ apikey: 'OPTKEY01' })
    credentialIs(fetchdef.headers['authorization'], 'OPTKEY01')

    // No feature, no instance: the accessor is the only way in.
    assert.equal(sdk.secrets(), undefined)
  })


  test('inactive: no apikey means no authorization header', async () => {
    const { fetchdef } = await prepared({})
    assert.equal(fetchdef.headers['authorization'], undefined)
  })


  test('active: apikey option still wins over the chain', async () => {
    process.env[ENVPREFIX + 'APIKEY'] = 'ENVKEY01'
    const { sdk, fetchdef } = await prepared(
      Object.assign({ apikey: 'OPTKEY01' }, envchain()))

    credentialIs(fetchdef.headers['authorization'], 'OPTKEY01')

    // The explicit option is a real store, not a special case: a directed
    // read names it like any other.
    assert.equal(await sdk.secrets().getfrom('options', 'apikey'), 'OPTKEY01')
  })


  // The three ways an apikey can be "not given", pinned together because
  // they are easy to conflate and only one of them is a suppression.
  //
  // makeOptions normalises an omitted apikey to '' before features
  // initialise, so by init time omitted and explicit-empty are
  // indistinguishable — both defer to the chain, deliberately.

  test('active: an OMITTED apikey defers to the chain', async () => {
    process.env[ENVPREFIX + 'APIKEY'] = 'ENVKEY01'
    const { fetchdef } = await prepared(envchain())
    credentialIs(fetchdef.headers['authorization'], 'ENVKEY01')
  })


  test('active: an explicitly EMPTY apikey also defers to the chain', async () => {
    process.env[ENVPREFIX + 'APIKEY'] = 'ENVKEY01'
    const { fetchdef } = await prepared(
      Object.assign({ apikey: '' }, envchain()))
    credentialIs(fetchdef.headers['authorization'], 'ENVKEY01')
  })


  // `auth: null` — the documented way to disable auth outright, which
  // prepareAuth honours before it ever reads the apikey.
  //
  // This needs an explicit guard because struct 0.3.2 nearly removed it in
  // silence. Under 0.0.10, getprop returned a stored null as null, so
  // validate saw `auth: null` as a non-map and REJECTED it for any SDK
  // whose optspec supplies an `auth` default. Under 0.3.2 getprop treats a
  // stored null as "no value", so the default fires instead and the
  // suppression became "use default auth" — transmitting a credential the
  // caller explicitly asked not to send. makeOptions now captures
  // suppliedness BEFORE validate and restores the null after it.
  //
  // No corpus entry could catch this: corpus nulls travel as the
  // '__NULL__' string, so real-JSON-null semantics are invisible to every
  // port's shared fixtures.
  test('active: auth null suppresses the credential, chain or no chain',
    async () => {
      process.env[ENVPREFIX + 'APIKEY'] = 'ENVKEY01'
      const { sdk, fetchdef } = await prepared(
        Object.assign({ auth: null }, envchain()))

      // Nothing on the wire, even though the chain would have resolved.
      assert.equal(fetchdef.headers['authorization'], undefined)

      // The suppression survives option validation rather than being
      // replaced by the optspec's default auth map.
      assert.equal(sdk.options().auth, null)
    })


  test('active: auth null suppresses an EXPLICIT apikey too', async () => {
    const { fetchdef } = await prepared(
      Object.assign({ apikey: 'OPTKEY01', auth: null }, envchain()))
    assert.equal(fetchdef.headers['authorization'], undefined)
  })


  test('active: custom provider objects are accepted verbatim', async () => {
    const asked = []
    const { fetchdef } = await prepared({
      feature: {
        secrets: {
          active: true,
          providers: [{
            lookup(name) { asked.push(name); return 'CUSTOM01' },
            describe() { return 'custom:test' },
          }],
        },
      },
    })
    credentialIs(fetchdef.headers['authorization'], 'CUSTOM01')
    assert.deepEqual(asked, ['apikey'])
  })


  test('active: a miss everywhere leaves the header off', async () => {
    const { sdk, fetchdef } = await prepared(envchain())
    assert.equal(fetchdef.headers['authorization'], undefined)
    assert.equal(sdk.options().apikey, '')
  })


  // sekreto's miss-vs-error invariant: a MISS falls through to the next
  // provider, an ERROR does not. A broken vault must never degrade into an
  // unauthenticated request.
  //
  // On the DIRECT path the error is RETURNED, not thrown: _rawRequest
  // awaits prepare() outside its try, and direct()/graphql() are documented
  // to return a value or an Error and never reject.
  test('active: a provider ERROR is returned by prepare, not thrown',
    async () => {
      const sdk = SDK.test({}, {
        feature: {
          secrets: {
            active: true,
            providers: [{
              lookup(_name) { throw new Error('vault unreachable') },
              describe() { return 'broken:test' },
            }],
          },
        },
      })

      const out = await sdk.prepare({ path: '/' })

      assert.ok(out instanceof Error, 'expected an Error value, got ' + String(out))
      assert.match(String(out.message), /vault unreachable/)
    })


  // THE RAW PATHS, which run NO feature hooks at all. If resolution lived
  // only in the PreSpec hook these would send an unauthenticated request
  // and never notice; they are covered because prepare() resolves.
  //
  // A LIVE client, deliberately NOT SDK.test. Test mode REPLACES
  // `ctx.utility.fetcher` with its own in-memory mock (TestFeature does it
  // at init), so a counter hung off `system.fetch` is never reached: under
  // SDK.test both "no request was sent" AND "the call failed" hold for a
  // healthy SDK carrying no secrets feature at all, and the pair asserts
  // nothing. An assertion that cannot fail pins no rule.
  //
  // So each case proves its own counter FIRST, with the same construction
  // and a WORKING provider: one request must reach `system.fetch` carrying
  // the resolved credential. Only then does a zero from the broken
  // provider mean REFUSED rather than UNWIRED. And the failure is matched
  // on the provider's own message, so an unrelated failure (a missing
  // route, a blocked op) cannot stand in for fail-closed.
  const RAWBASE = 'http://raw.test/api'


  // A transport that records every call it is handed, so "sent" is a fact
  // about the wire rather than about the mock.
  function countingFetch() {
    const stub = { sent: 0, calls: [] }
    stub.fetch = async (url, init) => {
      stub.sent++
      stub.calls.push({
        url,
        init,
        auth: ((init || {}).headers || {})['authorization'],
      })
      return { status: 200, json: async () => ({ ok: true }), headers: {} }
    }
    return stub
  }


  // `allow.op` is named explicitly: a project that narrows the default set
  // would otherwise turn these into a false RED (the control leg refused
  // before it reached the transport), and the rule under test lives in
  // prepare(), downstream of the allow gate either way.
  function rawSdk(stub, provider) {
    return new SDK({
      base: RAWBASE,
      allow: { op: 'direct,graphql' },
      system: { fetch: stub.fetch },
      feature: { secrets: { active: true, providers: [provider] } },
    })
  }


  const BROKENPROVIDER = {
    lookup(_name) { throw new Error('vault unreachable') },
    describe() { return 'broken:test' },
  }

  const WORKINGPROVIDER = {
    lookup(name) { return 'apikey' === name ? 'RAWKEY01' : undefined },
    describe() { return 'working:test' },
  }


  // What went out, for a failure message that names the leak rather than
  // just its count.
  function wire(stub) {
    return stub.calls.map((c) => c.url + ' auth=' + JSON.stringify(c.auth)).join(', ')
  }


  test('active: a provider ERROR fails direct() rather than sending', async () => {
    // THE RULE, asserted first so a regression reports the leak itself.
    const stub = countingFetch()
    const res = await rawSdk(stub, BROKENPROVIDER).direct({ path: '/thing' })

    assert.equal(stub.sent, 0,
      'a request must not go out unauthenticated because a provider broke,' +
      ' but one reached the transport: ' + wire(stub))
    assert.ok(res instanceof Error,
      'expected the provider Error, got: ' + JSON.stringify(res))
    assert.match(String(res.message), /vault unreachable/)

    // CONTROL, which makes that zero mean REFUSED rather than UNWIRED: the
    // same construction with a WORKING provider must reach the same
    // transport, once, carrying the credential.
    const control = countingFetch()
    const ok = await rawSdk(control, WORKINGPROVIDER).direct({ path: '/thing' })

    assert.ok(ok && true === ok.ok,
      'the control request failed: ' + JSON.stringify(ok))
    assert.equal(control.sent, 1,
      'the control request never reached system.fetch, so this test cannot' +
      ' observe a request going out at all')
    credentialIs(control.calls[0].auth, 'RAWKEY01')
  })


  test('active: a provider ERROR fails graphql() rather than sending', async () => {
    const stub = countingFetch()
    const res = await rawSdk(stub, BROKENPROVIDER).graphql('{ thing }', {})

    assert.equal(stub.sent, 0,
      'a graphql request must not go out unauthenticated,' +
      ' but one reached the transport: ' + wire(stub))
    assert.ok(res instanceof Error,
      'expected the provider Error, got: ' + JSON.stringify(res))
    assert.match(String(res.message), /vault unreachable/)

    const control = countingFetch()
    const ok = await rawSdk(control, WORKINGPROVIDER).graphql('{ thing }', {})

    assert.ok(ok && true === ok.ok,
      'the control request failed: ' + JSON.stringify(ok))
    assert.equal(control.sent, 1,
      'the control request never reached system.fetch, so this test cannot' +
      ' observe a request going out at all')
    credentialIs(control.calls[0].auth, 'RAWKEY01')
  })


  // A settled promise must not be held forever. Holding a REJECTED one
  // meant a transient vault outage poisoned the client permanently: every
  // later operation kept failing with the original error long after the
  // vault recovered.
  test('active: a provider recovers after a transient failure', async () => {
    let calls = 0
    const sdk = SDK.test({}, {
      feature: {
        secrets: {
          active: true,
          providers: [{
            lookup(_name) {
              calls++
              if (1 === calls) throw new Error('vault unreachable')
              return 'RECOVERED01'
            },
            describe() { return 'flaky:test' },
          }],
        },
      },
    })

    const first = await sdk.prepare({ path: '/' })
    assert.ok(first instanceof Error, 'first attempt should surface the outage')

    const second = await sdk.prepare({ path: '/' })
    assert.ok(!(second instanceof Error), 'second attempt should recover, got ' + String(second))
    credentialIs(second.headers['authorization'], 'RECOVERED01')
  })


  // `cache: false` is documented as "every resolve() asks the chain again".
  // Caching the settled promise made that a lie.
  test('active: cache false asks the chain on every resolve', async () => {
    let calls = 0
    const sdk = SDK.test({}, {
      feature: {
        secrets: {
          active: true,
          cache: false,
          providers: [{
            lookup(_name) { calls++; return 'KEY' + calls },
            describe() { return 'counting:test' },
          }],
        },
      },
    })

    await sdk.prepare({ path: '/' })
    await sdk.prepare({ path: '/' })

    assert.ok(1 < calls, 'the chain was asked once and cached, despite cache: false')
  })


  // A MISS IS NOT A CACHEABLE ANSWER — sekreto's own rule, which this
  // feature used to override from the layer above.
  //
  // Default caching here, deliberately: `cache: true` is about holding a
  // HIT, and holding the settled promise after a miss meant the chain was
  // never asked again for the life of the client. A secret provisioned
  // after startup (a mounted file, a vault policy granted a minute late)
  // was invisible forever, and the only workaround was giving up hit
  // caching entirely.
  test('active: a MISS is re-asked, so a late secret is picked up',
    async () => {
      let calls = 0
      const sdk = SDK.test({}, {
        feature: {
          secrets: {
            active: true,
            providers: [{
              lookup(_name) {
                calls++
                // Absent on the first ask, present on the second.
                return 1 < calls ? 'LATEKEY' : undefined
              },
              describe() { return 'late:test' },
            }],
          },
        },
      })

      const first = await sdk.prepare({ path: '/' })
      assert.equal(first.headers['authorization'], undefined,
        'the first resolve missed, so no credential should go out')

      const second = await sdk.prepare({ path: '/' })
      credentialIs(second.headers['authorization'], 'LATEKEY')

      assert.ok(1 < calls,
        'the chain was asked once and the MISS cached: a secret that ' +
        'appears later can never be picked up')
    })


  // The other half of the same rule: a HIT is still cached by default, so
  // the fix above must not turn every request into a chain walk.
  test('active: a HIT is still cached by default', async () => {
    let calls = 0
    const sdk = SDK.test({}, {
      feature: {
        secrets: {
          active: true,
          providers: [{
            lookup(_name) { calls++; return 'KEY' + calls },
            describe() { return 'counting:test' },
          }],
        },
      },
    })

    await sdk.prepare({ path: '/' })
    await sdk.prepare({ path: '/' })

    assert.equal(calls, 1,
      'a hit must be cached under the default cache: true')
  })


  test('active: secret name is configurable', async () => {
    process.env[ENVPREFIX + 'API_TOKEN'] = 'TOKKEY01'
    try {
      const { fetchdef } = await prepared(envchain({ name: 'api.token' }))
      credentialIs(fetchdef.headers['authorization'], 'TOKKEY01')
    }
    finally {
      delete process.env[ENVPREFIX + 'API_TOKEN']
    }
  })


  test('active: sekreto is live for arbitrary secrets and redaction', async () => {
    const { sdk } = await prepared({
      feature: {
        secrets: {
          active: true,
          providers: [{ kind: 'memory', values: { DB_PASSWORD: 'dbpass01' } }],
        },
      },
    })

    const secrets = sdk.secrets()
    assert.equal(await secrets.get('db.password'), 'dbpass01')
    assert.equal(
      secrets.redact('the password is dbpass01, keep it safe'),
      'the password is [redacted], keep it safe')
  })


  // THE PROVIDER VOCABULARY IS NON-EMPTY.
  //
  // js-specific, and the one failure no other port can have. Config.js
  // requires SecretsFeature.js at its top and assigns module.exports at
  // the END of its body, so a top-level `require('../../Config')` in the
  // feature reads FEATURE_PLUGINS as undefined — and so does a kept module
  // handle, because Config REPLACES module.exports rather than adding to
  // it. The SDK would then carry every plugin module its model selected
  // and refuse every one of their kinds at runtime, while every test that
  // only uses built-in kinds stayed green.
  //
  // Conditional on the module being present, because this file ships to
  // projects that select the feature without the `vault` plugin group.
  test('active: a selected plugin kind is in the SDK vocabulary', async () => {
    let present = true
    try {
      require('../../../src/feature/secrets/sekreto/plugins/hashicorp')
    }
    catch (_err) {
      present = false
    }

    if (!present) {
      // No vault group in this project's model: nothing to assert.
      return
    }

    // Construction is where an unknown kind is refused, so the Sekreto
    // being built at all IS the regression check. The memory store comes
    // FIRST so sekreto's first-hit rule answers from it and the vault is
    // never contacted — the kind has to be declarable, not reachable.
    const sdk = SDK.test({}, {
      feature: {
        secrets: {
          active: true,
          providers: [
            { kind: 'memory', values: { APIKEY: 'VOCAB01' } },
            { kind: 'hashicorp', addr: 'https://vault.test', token: 'x' },
          ],
        },
      },
    })

    const fetchdef = await sdk.prepare({ path: '/' })
    assert.ok(!(fetchdef instanceof Error), String(fetchdef))
    credentialIs(fetchdef.headers['authorization'], 'VOCAB01')
  })


  // The bridge that makes the whole design work: resolution is async, the
  // auth header is built synchronously, and entity ops await
  // featureHook('PreSpec') before makeSpec — so that is where the lookup
  // happens and still lands in time.
  //
  // The entity is discovered from the SDK's own config rather than named,
  // because this file is a TEMPLATE: it ships to every project, and no
  // project's entity names are known here.
  test('active: entity ops resolve via the PreSpec hook', async () => {
    process.env[ENVPREFIX + 'APIKEY'] = 'ENVKEY02'

    const sdk = SDK.test({}, envchain())

    // SEARCH for a usable op rather than taking the first entity and
    // hoping. An API's first entity by name need not have a `list` — and
    // when it does not, `sdk[Accessor]().list()` throws a TypeError that
    // the catch below swallows, so the assertion fails with "PreSpec did
    // not run" while the real cause is that no op was ever called. Not
    // hypothetical: sdkgen's own generate fixture has seven entities and
    // the first of them, `ambient`, has no list.
    let op = null
    for (const name of Object.keys(sdk.options().entity || {})) {
      const accessor = name.charAt(0).toUpperCase() + name.slice(1)
      if ('function' !== typeof sdk[accessor]) continue
      const ent = sdk[accessor]()
      if (null != ent && 'function' === typeof ent.list) {
        op = () => ent.list()
        break
      }
    }

    if (null == op) {
      // An SDK with no listable entity has no PreSpec path to exercise.
      return
    }

    // Before any op, nothing has been resolved.
    assert.equal(sdk.options().apikey, '')

    // The op itself may fail (no seeded data, no live API) — irrelevant
    // here. What matters is that the awaited PreSpec hook ran and the
    // credential reached the live options before the spec was built.
    try {
      await op()
    }
    catch (_err) { }

    assert.equal(sdk.options().apikey, 'ENVKEY02',
      'the entity op did not resolve the secret through PreSpec')
  })

})


// ACCESS-TOKEN EXCHANGE.
//
// The shape these tests pin: what the chain resolves is a REFRESH token,
// which is POSTed to a token endpoint for a short-lived ACCESS token; the
// access token is what the Authorization header carries; and when the API
// answers 401 the client buys another and tries the same request again,
// once.
//
// A LIVE client throughout, with `system.fetch` stubbed. Test mode is
// deliberately excluded here — it buys nothing (see SecretsFeature._buy),
// which is the subject of its own test at the end.
describe('secrets exchange', () => {

  const BASE = 'http://exchange.test/api'
  const REFRESH = 'REFRESH01'


  beforeEach(() => {
    delete process.env[ENVPREFIX + 'REFRESH_TOKEN']
  })


  // A stub standing in for both endpoints the flow touches: the token
  // endpoint, and everything else.
  //
  // `apiStatus` is a SCRIPT — one status per API call, the last repeating —
  // so a case can say "401 then 200" without counting calls itself.
  function stubfetch(opts) {
    const o = opts || {}
    const tokens = o.tokens || ['ACCESS01', 'ACCESS02', 'ACCESS03']
    const apiStatus = o.apiStatus || [200]

    const calls = []
    let issued = 0
    let apicall = -1

    const fetch = async (url, init) => {
      calls.push({ url, init, auth: (init.headers || {})['authorization'] })

      if (url.endsWith('/' + (o.path || 'auth/token'))) {
        if (true === o.tokenfails) {
          return { status: 401, json: async () => ({ error: 'nope' }), headers: {} }
        }
        const body = {}
        body[o.response || 'access_token'] = tokens[Math.min(issued, tokens.length - 1)]
        issued++
        return { status: 200, json: async () => body, headers: {} }
      }

      apicall++
      const status = apiStatus[Math.min(apicall, apiStatus.length - 1)]
      return { status, json: async () => ({ ok: status < 400 }), headers: {} }
    }

    return {
      fetch,
      calls,
      // Only the calls that went to the API, in order.
      api: () => calls.filter((c) => !c.url.endsWith('/' + (o.path || 'auth/token'))),
      token: () => calls.filter((c) => c.url.endsWith('/' + (o.path || 'auth/token'))),
    }
  }


  // Same rule as credentialIs, reading the header off a recorded call.
  function authIs(call, token) {
    credentialIs(null == call ? undefined : call.auth, token)
  }


  function exchangeSdk(stub, extra) {
    return new SDK({
      base: BASE,
      system: { fetch: stub.fetch },
      feature: {
        secrets: Object.assign({
          active: true,
          name: 'refresh_token',
          providers: [{ kind: 'env', prefix: ENVPREFIX }],
          exchange: { active: true },
        }, extra || {}),
      },
    })
  }


  test('the refresh token buys an access token, and the request carries it', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    const stub = stubfetch()
    const sdk = exchangeSdk(stub)

    await sdk.direct({ path: '/thing' })

    assert.equal(stub.token().length, 1, 'expected exactly one token purchase')
    assert.deepEqual(
      JSON.parse(stub.token()[0].init.body), { refresh_token: REFRESH },
      'the refresh token is sent in the request field')

    assert.equal(stub.api().length, 1)
    authIs(stub.api()[0], 'ACCESS01')
  })


  test('an explicit exchange.refresh wins over the chain', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = 'FROMCHAIN'

    const stub = stubfetch()
    const sdk = exchangeSdk(stub, { exchange: { active: true, refresh: 'EXPLICIT01' } })

    await sdk.direct({ path: '/thing' })

    assert.deepEqual(
      JSON.parse(stub.token()[0].init.body), { refresh_token: 'EXPLICIT01' })
  })


  test('one purchase serves many requests', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    const stub = stubfetch()
    const sdk = exchangeSdk(stub)

    await sdk.direct({ path: '/one' })
    await sdk.direct({ path: '/two' })
    await sdk.direct({ path: '/three' })

    assert.equal(stub.token().length, 1,
      'a token still working must not be re-bought')
    assert.equal(stub.api().length, 3)
  })


  test('concurrent first requests share ONE purchase', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    const stub = stubfetch()
    const sdk = exchangeSdk(stub)

    await Promise.all([
      sdk.direct({ path: '/a' }),
      sdk.direct({ path: '/b' }),
      sdk.direct({ path: '/c' }),
    ])

    assert.equal(stub.token().length, 1,
      'four operations at once must not open four token requests')
  })


  test('a 401 buys another token and retries the SAME request', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    // First API call is refused, the retry succeeds.
    const stub = stubfetch({ apiStatus: [401, 200] })
    const sdk = exchangeSdk(stub)

    const res = await sdk.direct({ path: '/thing' })

    assert.equal(stub.token().length, 2, 'expected a second token purchase')
    assert.equal(stub.api().length, 2, 'expected the request to be retried')

    authIs(stub.api()[0], 'ACCESS01')
    // The retry must carry the NEW token, not the spent one.
    authIs(stub.api()[1], 'ACCESS02')

    assert.equal(res.ok, true, 'the caller sees the successful retry')
  })


  test('the retry happens once, not in a loop', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    // Every API call is refused: a second 401 on a token bought moments ago
    // is a real failure, and spinning on it would hang instead of failing.
    const stub = stubfetch({ apiStatus: [401] })
    const sdk = exchangeSdk(stub)

    await sdk.direct({ path: '/thing' })

    assert.equal(stub.api().length, 2, 'exactly one retry')
    assert.equal(stub.token().length, 2)
  })


  test('a status outside exchange.statuses is not an expiry', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    const stub = stubfetch({ apiStatus: [403] })
    const sdk = exchangeSdk(stub)

    await sdk.direct({ path: '/thing' })

    assert.equal(stub.api().length, 1, '403 is not in the default statuses')
    assert.equal(stub.token().length, 1)
  })


  test('exchange.statuses is configurable', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    const stub = stubfetch({ apiStatus: [403, 200] })
    const sdk = exchangeSdk(stub,
      { exchange: { active: true, statuses: [403] } })

    await sdk.direct({ path: '/thing' })

    assert.equal(stub.api().length, 2, '403 was declared an expiry')
  })


  test('the request and response field names are configurable', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    const stub = stubfetch({ response: 'token', path: 'oauth/grant' })
    const sdk = exchangeSdk(stub, {
      exchange: {
        active: true,
        path: 'oauth/grant',
        request: 'grant',
        response: 'token',
      },
    })

    await sdk.direct({ path: '/thing' })

    assert.equal(stub.token().length, 1)
    assert.ok(stub.token()[0].url.endsWith('/oauth/grant'),
      'the token endpoint is relative to base: ' + stub.token()[0].url)
    assert.deepEqual(JSON.parse(stub.token()[0].init.body), { grant: REFRESH })
    authIs(stub.api()[0], 'ACCESS01')
  })


  test('an explicit apikey is spent before anything is bought', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    // A caller who already holds an access token should use it; expiry is
    // what moves them onto the exchange, and the API is what says so.
    const stub = stubfetch({ apiStatus: [200] })
    const sdk = new SDK({
      base: BASE,
      apikey: 'HELDTOKEN01',
      system: { fetch: stub.fetch },
      feature: {
        secrets: {
          active: true,
          name: 'refresh_token',
          providers: [{ kind: 'env', prefix: ENVPREFIX }],
          exchange: { active: true },
        },
      },
    })

    await sdk.direct({ path: '/thing' })

    assert.equal(stub.token().length, 0, 'nothing needed buying')
    authIs(stub.api()[0], 'HELDTOKEN01')
  })


  test('a held apikey that has expired falls through to the exchange', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    const stub = stubfetch({ apiStatus: [401, 200] })
    const sdk = new SDK({
      base: BASE,
      apikey: 'STALETOKEN01',
      system: { fetch: stub.fetch },
      feature: {
        secrets: {
          active: true,
          name: 'refresh_token',
          providers: [{ kind: 'env', prefix: ENVPREFIX }],
          exchange: { active: true },
        },
      },
    })

    await sdk.direct({ path: '/thing' })

    authIs(stub.api()[0], 'STALETOKEN01')
    authIs(stub.api()[1], 'ACCESS01')
  })


  test('no refresh token anywhere is an error, not an unauthenticated call', async () => {
    const stub = stubfetch()
    const sdk = exchangeSdk(stub)

    const res = await sdk.direct({ path: '/thing' })

    assert.ok(res instanceof Error || (res && false === res.ok),
      'expected a failure, got: ' + JSON.stringify(res))
    assert.equal(stub.api().length, 0,
      'a request must not go out unauthenticated because the chain was empty')
  })


  test('a failing token endpoint surfaces the API refusal, not a spin', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    // The first purchase succeeds; the second (after the 401) does not.
    const stub = stubfetch({ apiStatus: [401] })
    const failing = {
      ...stub,
      fetch: async (url, init) => {
        const res = await stub.fetch(url, init)
        return url.endsWith('/auth/token') && 1 < stub.token().length
          ? { status: 500, json: async () => ({}), headers: {} }
          : res
      },
    }

    const sdk = exchangeSdk(failing)
    const res = await sdk.direct({ path: '/thing' })

    assert.ok(null != res, 'the caller got an answer rather than a hang')
    assert.equal(stub.api().length, 1, 'no retry after a failed purchase')
  })


  test('auth: null suppresses the credential, refusal or not', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    // `auth: null` is the documented way to send no credential at all.
    // A refusal of a deliberately unauthenticated request is not an
    // expired token: buying one and retrying would transmit exactly the
    // credential the caller suppressed.
    const stub = stubfetch({ apiStatus: [401] })
    const sdk = new SDK({
      base: BASE,
      auth: null,
      system: { fetch: stub.fetch },
      feature: {
        secrets: {
          active: true,
          name: 'refresh_token',
          providers: [{ kind: 'env', prefix: ENVPREFIX }],
          exchange: { active: true },
        },
      },
    })

    await sdk.direct({ path: '/thing' })

    assert.equal(stub.api().length, 1, 'a suppressed request must not be retried')
    assert.equal(stub.api()[0].auth, undefined,
      'no credential may be sent when auth is suppressed')

    // AND NO PURCHASE. This is the half the API-call assertions cannot see:
    // resolve() runs before _withRefresh's suppression check, so the
    // refresh token used to go to the token endpoint in a request body
    // even here. Stopping the retry does not unsend it.
    assert.equal(stub.token().length, 0,
      'auth: null suppressed the credential but the refresh token was ' +
      'still POSTed to the exchange endpoint')
  })


  test('a token another request already bought is spent, not re-bought', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    // STAGGERED 401s: the case the shared in-flight purchase does NOT
    // cover. Two requests go out on the same token; the first is refused,
    // buys a new one and clears the shared promise; only then is the
    // second refused. Buying again there is a wasted exchange, and on a
    // provider that invalidates the previous credential on issuance it
    // breaks the first request's own retry.
    //
    // Driven through the transport wrapper directly, because the race is
    // in WHEN the refusal arrives relative to another request's refresh,
    // and that is not something two ordinary calls can be made to stage.
    const stub = stubfetch()
    const sdk = exchangeSdk(stub)

    await sdk.direct({ path: '/warmup' })
    const bought = stub.token().length

    const feature = sdk._secrets
    const fetchdef = { headers: { authorization: 'Bearer STALE01' } }

    sdk._options.apikey = 'STALE01'

    let calls = 0
    const inner = async () => {
      calls++
      if (1 === calls) {
        // While this request was in flight, another one refreshed.
        sdk._options.apikey = 'ACCESS09'
        return { status: 401, json: async () => ({}), headers: {} }
      }
      return { status: 200, json: async () => ({ ok: true }), headers: {} }
    }

    const res = await feature._withRefresh({}, BASE + '/two', fetchdef, inner)

    assert.equal(res.status, 200)
    assert.equal(calls, 2, 'the request was retried once')
    assert.equal(stub.token().length, bought,
      'the retry must reuse the token another request already bought')
    authIs({ auth: fetchdef.headers.authorization }, 'ACCESS09')
  })


  test('exchange off leaves the feature exactly as it was', async () => {
    process.env[ENVPREFIX + 'APIKEY'] = 'PLAINKEY01'

    const { fetchdef } = await prepared(envchain())

    credentialIs(fetchdef.headers['authorization'], 'PLAINKEY01')
    delete process.env[ENVPREFIX + 'APIKEY']
  })


  test('test mode buys nothing and needs no token endpoint', async () => {
    process.env[ENVPREFIX + 'REFRESH_TOKEN'] = REFRESH

    const stub = stubfetch()
    const sdk = SDK.test({}, {
      base: BASE,
      system: { fetch: stub.fetch },
      feature: {
        secrets: {
          active: true,
          name: 'refresh_token',
          providers: [{ kind: 'env', prefix: ENVPREFIX }],
          exchange: { active: true },
        },
      },
    })

    const fetchdef = await sdk.prepare({ path: '/' })

    assert.equal(stub.calls.length, 0, 'test mode must not do IO')
    // A deterministic placeholder, so offline suites need no configuration.
    credentialIs(fetchdef.headers['authorization'], 'test-access_token')
  })

})
