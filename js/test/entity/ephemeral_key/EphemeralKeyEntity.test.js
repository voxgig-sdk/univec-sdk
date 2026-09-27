
const envlocal = __dirname + '/../../../.env.local'
require('../../utility').loadEnvLocal(envlocal)

const Path = require('node:path')
const Fs = require('node:fs')

const { test, describe, afterEach } = require('node:test')
const assert = require('node:assert')
const { createLiveTransport } = require('../../live-runner')
const { runLiveEntity } = require('../../live-entity')


const { UnivecSDK, BaseFeature, stdutil, config } = require('../../..')

const {
  envOverride,
  liveClientOptions,
  liveDelay,
  makeCtrl,
  makeMatch,
  makeReqdata,
  makeStepData,
  makeValid,
} = require('../../utility')


describe('EphemeralKeyEntity', async () => {

  // Per-test live pacing. Delay is read from sdk-test-control.json's
  // `test.live.delayMs`; only sleeps when UNIVEC_TEST_LIVE=TRUE.
  afterEach(liveDelay('UNIVEC_TEST_LIVE'))

  test('instance', async () => {
    const testsdk = UnivecSDK.test()
    const ent = testsdk.EphemeralKey()
    assert(null != ent)
  })


  test('basic', async (t) => {

    if (process.env.UNIVEC_TEST_LIVE === 'TRUE') { t.skip('Covered by live operation scenarios'); return }
    const setup = basicSetup()
    if (setup.live) {
      return runLiveEntity(setup, {"active":true,"alias":{"field":{}},"fields":{"dailyLimit":{"a":true,"h":"Daily Limit","n":"dailyLimit","r":true,"sh":"Calls permitted per day.","t":"`$INTEGER`","key$":"dailyLimit","index$":0},"dailyUsed":{"a":true,"h":"Daily Used","n":"dailyUsed","r":true,"sh":"Calls already used today.","t":"`$INTEGER`","key$":"dailyUsed","index$":1},"key":{"a":true,"h":"Key","n":"key","r":true,"sh":"The ephemeral API key, prefixed `eph_`.","t":"`$STRING`","key$":"key","index$":2},"resetsAt":{"a":true,"fo":"date-time","h":"Resets At","n":"resetsAt","r":true,"sh":"When the daily allowance resets.","t":"`$STRING`","key$":"resetsAt","index$":3}},"name":"ephemeral_key","op":{"create":{"input":"data","name":"create","points":[{"a":true,"co":{"id":"POST /v1/ephemeral/key","source":"openapi3","version":2},"g":{},"k":"http","li":{"assert":{"nonempty":["key"]},"auth":"public","id":"key","retention":"No deletion endpoint; issued key is subject to the service daily allowance"},"m":"POST","o":"/v1/ephemeral/key","q":{},"r":{},"s":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"key"}],"t":{"req":"`reqdata`","res":"`body.data`"},"index$":0}],"key$":"create"}},"relations":{"ancestors":[]},"key$":"ephemeral_key","name__orig":"ephemeral_key","Name":"EphemeralKey","name_":"ephemeral_key","name-":"ephemeral-key","NAME":"EPHEMERAL_KEY","index$":2}, {"active":true,"entity":"ephemeral_key","key$":"BasicEphemeralKeyFlow","kind":"basic","name":"BasicEphemeralKeyFlow","param":{},"step":[{"a":true,"d":{},"i":{"ref":"ephemeral_key_ref01"},"m":{},"o":"create","s":[],"v":[],"index$":0}]}, 'EphemeralKey', {"POST /v1/ephemeral/key":{"protocol":"http","requestBody":{"required":false,"content":{"application/json":{"schema":{"type":"object","additionalProperties":false,"index$":1},"example":{}}}},"parameters":[]}})
    }
    const client = setup.client
    const struct = setup.struct

    const isempty = struct.isempty
    const select = struct.select


    // CREATE
    const ephemeral_key_ref01_ent = client.EphemeralKey()
    let ephemeral_key_ref01_data = setup.data.new.ephemeral_key['ephemeral_key_ref01']

    ephemeral_key_ref01_data = (await ephemeral_key_ref01_ent.create(ephemeral_key_ref01_data)).data()
    assert(null != ephemeral_key_ref01_data)


  })
})



function basicSetup(extra) {
  // TODO: fix test def options
  const options = {} // null

  // TODO: needs test utility to resolve path
  const entityDataFile =
    Path.resolve(__dirname,
      '../../../../.sdk/test/entity/ephemeral_key/EphemeralKeyTestData.json')

  // TODO: file ready util needed?
  const entityDataSource = Fs.readFileSync(entityDataFile).toString('utf8')

  // TODO: need a xlang JSON parse utility in voxgig/struct with better error msgs
  const entityData = JSON.parse(entityDataSource)

  options.entity = entityData.existing

  let client = UnivecSDK.test(options, extra)
  const struct = client.utility().struct
  const merge = struct.merge
  const transform = struct.transform

  let idmap = transform(
    ['ephemeral_key01','ephemeral_key02','ephemeral_key03'],
    {
      '`$PACK`': ['', {
        '`$KEY`': '`$COPY`',
        '`$VAL`': ['`$FORMAT`', 'upper', '`$COPY`']
      }]
    })

  const env = envOverride({
    'UNIVEC_TEST_EPHEMERAL_KEY_ENTID': idmap,
    'UNIVEC_TEST_LIVE': 'FALSE',
    'UNIVEC_TEST_EXPLAIN': 'FALSE',
    'UNIVEC_APIKEY': '',
  })

  idmap = env['UNIVEC_TEST_EPHEMERAL_KEY_ENTID']

  const live = 'TRUE' === env.UNIVEC_TEST_LIVE
  const transport = createLiveTransport()
  if (live) {
    const rawIds = process.env['UNIVEC_TEST_EPHEMERAL_KEY_ENTID']
    idmap = rawIds && rawIds.trim() ? JSON.parse(rawIds) : {}
    if (!idmap || Array.isArray(idmap) || typeof idmap !== 'object') {
      throw new Error('Live ENTID must be a JSON object')
    }
    client = new UnivecSDK(merge([
      // FIRST, so the generated fields below win: sdk-test-control.json's
      // test.client.options adds to the live client, it does not redirect it.
      liveClientOptions(),
      {
        apikey: env.UNIVEC_APIKEY,
      },
      // 'extra || {}', not a bare 'extra': struct.merge returns UNDEFINED when
      // the last entry is undefined, and basicSetup is normally called with no
      // argument at all - so a bare 'extra' silently discarded the apikey and
      // server values above and handed the SDK undefined.
      extra || {},
      { system: { fetch: transport.fetch } }
    ]))
  }

  const setup = {
    idmap,
    env,
    options,
    client,
    struct,
    data: entityData,
    explain: 'TRUE' === env.UNIVEC_TEST_EXPLAIN,
    live,
    transport,
    now: Date.now(),
  }

  return setup
}
  
