
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


  test('basic', async (t) => {

    if (process.env.UNIVEC_TEST_LIVE === 'TRUE') { t.skip('Covered by live operation scenarios'); return }
    const setup = basicSetup()
    if (setup.live) {
      return runLiveEntity(setup, {"active":true,"alias":{"field":{}},"fields":[{"active":true,"name":"eval","req":false,"short":"Retrieval-fidelity metrics for a convert model.","type":"`$OBJECT`","index$":0},{"active":true,"name":"executionProvider","req":false,"short":"Hardware backend, e.g.","type":"`$STRING`","index$":1},{"active":true,"name":"modelCard","req":false,"short":"Convert models only: training provenance and architecture detail.","type":"`$OBJECT`","index$":2},{"active":true,"name":"modelType","req":true,"short":"`embed` for text-to-vector models, `convert` for space-translation models.","type":"`$STRING`","index$":3},{"active":true,"name":"name","req":true,"short":"Model identifier used in requests.","type":"`$STRING`","index$":4},{"active":true,"name":"sequenceLen","req":false,"short":"Embed models only: maximum input sequence length.","type":"`$INTEGER`","index$":5},{"active":true,"name":"sourceDim","req":false,"short":"Convert models only: source vector dimension.","type":"`$INTEGER`","index$":6},{"active":true,"name":"sourceModel","req":false,"short":"Convert models only: the source model space.","type":"`$STRING`","index$":7},{"active":true,"name":"targetDim","req":true,"short":"Dimension of the produced vectors.","type":"`$INTEGER`","index$":8},{"active":true,"name":"targetModel","req":true,"short":"The model space produced.","type":"`$STRING`","index$":9}],"name":"model","op":{"list":{"input":"data","name":"list","points":[{"active":true,"args":{},"contract":{"id":"GET /v1/models","json":"{\"factSources\":{\"responses\":\"guide\"},\"live\":{\"assert\":{\"nonempty\":[\"\"]},\"auth\":\"public\",\"id\":\"models\"},\"operationId\":\"listModels\",\"parameters\":[],\"protocol\":\"http\",\"responses\":{\"200\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"data\":{\"items\":{\"oneOf\":[{\"properties\":{\"eval\":{\"description\":\"Retrieval-fidelity metrics for a convert model.\",\"properties\":{\"cosine_mean\":{\"format\":\"float\",\"type\":\"number\"},\"cosine_median\":{\"format\":\"float\",\"type\":\"number\"},\"cosine_std\":{\"format\":\"float\",\"type\":\"number\"},\"kendall_p_value\":{\"format\":\"float\",\"type\":\"number\"},\"kendall_tau\":{\"format\":\"float\",\"type\":\"number\"},\"mrr\":{\"description\":\"Mean reciprocal rank.\",\"format\":\"float\",\"type\":\"number\"},\"p_at_1\":{\"format\":\"float\",\"type\":\"number\"},\"p_at_10\":{\"format\":\"float\",\"type\":\"number\"},\"p_at_5\":{\"format\":\"float\",\"type\":\"number\"}},\"type\":\"object\"},\"executionProvider\":{\"description\":\"Hardware backend, e.g. `cpu`.\",\"type\":\"string\"},\"modelCard\":{\"additionalProperties\":true,\"description\":\"Convert models only: training provenance and architecture detail.\",\"type\":\"object\"},\"modelType\":{\"description\":\"`embed` for text-to-vector models, `convert` for space-translation models.\",\"enum\":[\"embed\",\"convert\"],\"type\":\"string\"},\"name\":{\"description\":\"Model identifier used in requests.\",\"type\":\"string\"},\"sequenceLen\":{\"description\":\"Embed models only: maximum input sequence length.\",\"type\":\"integer\"},\"sourceDim\":{\"description\":\"Convert models only: source vector dimension.\",\"type\":\"integer\"},\"sourceModel\":{\"description\":\"Convert models only: the source model space.\",\"type\":\"string\"},\"targetDim\":{\"description\":\"Dimension of the produced vectors.\",\"type\":\"integer\"},\"targetModel\":{\"description\":\"The model space produced.\",\"type\":\"string\"}},\"required\":[\"name\",\"modelType\",\"targetModel\",\"targetDim\"],\"type\":\"object\"},{\"properties\":{\"executionProvider\":{\"type\":\"string\"},\"modelType\":{\"enum\":[\"convert-bridge\",\"embed-bridge\"],\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"restrictedTargets\":{\"items\":{\"type\":\"string\"},\"type\":\"array\"}},\"required\":[\"name\",\"modelType\",\"executionProvider\"],\"type\":\"object\"}]},\"type\":\"array\"},\"success\":{\"type\":\"boolean\"}},\"required\":[\"success\",\"data\"],\"type\":\"object\"}}},\"description\":\"Model list\"}},\"security\":[],\"securitySchemes\":{\"bearerAuth\":{\"description\":\"UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.\",\"scheme\":\"bearer\",\"type\":\"http\"}},\"securitySource\":\"operation\"}","source":"openapi3","version":1},"kind":"http","method":"GET","orig":"/v1/models","segments":[{"lit":"v1"},{"lit":"models"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"index$":0}],"key$":"list"}},"relations":{"ancestors":[]},"key$":"model","name__orig":"model","Name":"Model","name_":"model","name-":"model","NAME":"MODEL","index$":3}, {"active":true,"entity":"model","key$":"BasicModelFlow","kind":"basic","name":"BasicModelFlow","param":{},"step":[{"active":true,"data":{},"input":{},"match":{},"op":"list","spec":[],"valid":[{"apply":"ItemExists","def":{"ref":"model_ref01"}}],"index$":0}]}, 'Model')
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
  
