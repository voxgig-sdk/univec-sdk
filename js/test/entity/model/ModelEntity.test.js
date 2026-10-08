
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


describe('ModelEntity', async () => {

  // Per-test live pacing. Delay is read from sdk-test-control.json's
  // `test.live.delayMs`; only sleeps when UNIVEC_TEST_LIVE=TRUE.
  afterEach(liveDelay('UNIVEC_TEST_LIVE'))

  test('instance', async () => {
    const testsdk = UnivecSDK.test()
    const ent = testsdk.Model()
    assert(null != ent)
  })


  class FailHook extends BaseFeature {
    constructor() {
      super()
      this.name = 'failhook'
      this.version = '0.0.1'
      this.active = true
      this.unexpected = 0
    }
    init() { }
    PreSpec() { throw new Error('model hook failed') }
    PreUnexpected() { this.unexpected++ }
  }

  test('stream-error', async () => {
    const offline = { net: { offline: true } }
    await assert.rejects(async () => {
      for await (const _item of UnivecSDK.test(offline).Model().stream('list')) { }
    }, /offline/)

    for await (const _item of UnivecSDK.test(offline).Model()
      .stream('list', undefined, { ctrl: { throw: false } })) { }

    if (null != config.feature?.rbac) {
      const denied = UnivecSDK.test(undefined, { feature: { rbac: { active: true, deny: true } } })
      await assert.rejects(async () => {
        for await (const _item of denied.Model().stream('list')) { }
      }, (err) => 'rbac_denied' === err.code)
    }
  })

  test('stream-ctrl', async () => {
    const explain = {}
    const ctrl = { explain }
    for await (const _item of UnivecSDK.test().Model().stream('list', undefined, { ctrl })) { }
    assert.deepStrictEqual(Object.keys(ctrl), ['explain'])
    assert(explain === ctrl.explain && 0 < Object.keys(explain).length)
  })

  test('unexpected', async () => {
    const hook = new FailHook()
    const client = new UnivecSDK({ feature: { test: { active: true } }, extend: [hook] })
    await assert.rejects(client.Model().list(), /hook failed/)
    assert(0 < hook.unexpected)

    const fired = hook.unexpected
    assert.strictEqual(await client.Model().list(undefined, { throw: false }), undefined)
    assert(fired < hook.unexpected)
  })

  test('validate', async (t) => {
    if (null == config.feature?.validate) {
      t.skip('feature not present in this SDK: validate')
      return
    }
    const client = UnivecSDK.test(undefined, { feature: { validate: { active: true } } })
    await assert.rejects(client.Model().list({"executionProvider":1}),
      (err) => 'validate_failed' === err.code)
  })



  test('basic', async (t) => {

    if (process.env.UNIVEC_TEST_LIVE === 'TRUE') { t.skip('Covered by live operation scenarios'); return }
    const setup = basicSetup()
    if (setup.live) {
      return runLiveEntity(setup, {"active":true,"alias":{"field":{}},"fields":{"eval":{"a":true,"h":"Eval","n":"eval","r":false,"sh":"Retrieval-fidelity metrics for a convert model.","t":"`$OBJECT`","key$":"eval","index$":0},"executionProvider":{"a":true,"h":"Execution Provider","n":"executionProvider","r":false,"sh":"Hardware backend, e.g.","t":"`$STRING`","key$":"executionProvider","index$":1},"modelCard":{"a":true,"h":"Model Card","n":"modelCard","r":false,"sh":"Convert models only: training provenance and architecture detail.","t":"`$OBJECT`","key$":"modelCard","index$":2},"modelType":{"a":true,"h":"Model Type","n":"modelType","r":true,"sh":"`embed` for text-to-vector models, `convert` for space-translation models.","t":"`$STRING`","key$":"modelType","index$":3},"name":{"a":true,"h":"Name","n":"name","r":true,"sh":"Model identifier used in requests.","t":"`$STRING`","key$":"name","index$":4},"sequenceLen":{"a":true,"h":"Sequence Len","n":"sequenceLen","r":false,"sh":"Embed models only: maximum input sequence length.","t":"`$INTEGER`","key$":"sequenceLen","index$":5},"sourceDim":{"a":true,"h":"Source Dim","n":"sourceDim","r":false,"sh":"Convert models only: source vector dimension.","t":"`$INTEGER`","key$":"sourceDim","index$":6},"sourceModel":{"a":true,"h":"Source Model","n":"sourceModel","r":false,"sh":"Convert models only: the source model space.","t":"`$STRING`","key$":"sourceModel","index$":7},"targetDim":{"a":true,"h":"Target Dim","n":"targetDim","r":true,"sh":"Dimension of the produced vectors.","t":"`$INTEGER`","key$":"targetDim","index$":8},"targetModel":{"a":true,"h":"Target Model","n":"targetModel","r":true,"sh":"The model space produced.","t":"`$STRING`","key$":"targetModel","index$":9}},"name":"model","op":{"list":{"input":"data","name":"list","points":[{"a":true,"co":{"id":"GET /v1/models","source":"openapi3","version":2},"g":{},"k":"http","li":{"assert":{"nonempty":[""]},"auth":"public","id":"models"},"m":"GET","o":"/v1/models","q":{},"r":{},"rs":{"kind":"json","media":"application/json"},"s":[{"lit":"v1"},{"lit":"models"}],"t":{"req":"`reqdata`","res":"`body.data`"},"index$":0}],"key$":"list"}},"relations":{"ancestors":[]},"key$":"model","name__orig":"model","Name":"Model","name_":"model","name-":"model","NAME":"MODEL","index$":3}, {"active":true,"entity":"model","key$":"BasicModelFlow","kind":"basic","name":"BasicModelFlow","param":{},"step":[{"a":true,"d":{},"i":{},"m":{},"o":"list","s":[],"v":[{"apply":"ItemExists","def":{"ref":"model_ref01"}}],"index$":0}]}, 'Model', {"GET /v1/models":{"protocol":"http","parameters":[]}}, { strict: LIVE_STRICT, t })
    }
    const client = setup.client
    const struct = setup.struct

    const isempty = struct.isempty
    const select = struct.select

    let model_ref01_data = Object.values(setup.data.existing.model)[0]

    // LIST
    const model_ref01_ent = client.Model()
    const model_ref01_match = {}

    const model_ref01_list = (await model_ref01_ent.list(model_ref01_match)).map((e) => e.data())


  })
})



// main.kit.test.live.strict is true (the default is true): a live
// request that fails, or a live test missing an input it needs,
// fails the test.
// An account with no record for a test to read skips it either way.
const LIVE_STRICT = true

function basicSetup(extra) {
  // TODO: fix test def options
  const options = {} // null

  // TODO: needs test utility to resolve path
  const entityDataFile =
    Path.resolve(__dirname,
      '../../../../.sdk/test/entity/model/ModelTestData.json')

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
    ['model01','model02','model03'],
    {
      '`$PACK`': ['', {
        '`$KEY`': '`$COPY`',
        '`$VAL`': ['`$FORMAT`', 'upper', '`$COPY`']
      }]
    })

  const env = envOverride({
    'UNIVEC_TEST_MODEL_ENTID': idmap,
    'UNIVEC_TEST_LIVE': 'FALSE',
    'UNIVEC_TEST_EXPLAIN': 'FALSE',
    'UNIVEC_APIKEY': '',
  })

  idmap = env['UNIVEC_TEST_MODEL_ENTID']

  const live = 'TRUE' === env.UNIVEC_TEST_LIVE
  const transport = createLiveTransport()
  if (live) {
    const rawIds = process.env['UNIVEC_TEST_MODEL_ENTID']
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
  
