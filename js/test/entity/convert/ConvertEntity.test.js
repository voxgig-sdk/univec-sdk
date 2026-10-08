
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


describe('ConvertEntity', async () => {

  // Per-test live pacing. Delay is read from sdk-test-control.json's
  // `test.live.delayMs`; only sleeps when UNIVEC_TEST_LIVE=TRUE.
  afterEach(liveDelay('UNIVEC_TEST_LIVE'))

  test('instance', async () => {
    const testsdk = UnivecSDK.test()
    const ent = testsdk.Convert()
    assert(null != ent)
  })


  test('validate', async (t) => {
    if (null == config.feature?.validate) {
      t.skip('feature not present in this SDK: validate')
      return
    }
    const client = UnivecSDK.test(undefined, { feature: { validate: { active: true } } })
    await assert.rejects(client.Convert().create({"embeddings":"x","source_model":1,"target_model":"x"}),
      (err) => 'validate_failed' === err.code)
  })



  test('basic', async (t) => {

    if (process.env.UNIVEC_TEST_LIVE === 'TRUE') { t.skip('Covered by live operation scenarios'); return }
    const setup = basicSetup()
    if (setup.live) {
      return runLiveEntity(setup, {"active":true,"alias":{"field":{}},"fields":{"embeddings":{"a":true,"h":"Embeddings","n":"embeddings","r":true,"sh":"Translated vectors, in the target model's dimension.","t":"`$ARRAY`","key$":"embeddings","index$":0},"source_model":{"a":true,"h":"Source Model","n":"source_model","r":true,"sh":"Model space the supplied vectors are currently in.","t":"`$STRING`","key$":"source_model","index$":1},"target_model":{"a":true,"h":"Target Model","n":"target_model","r":true,"sh":"Model space to translate into.","t":"`$STRING`","key$":"target_model","index$":2}},"name":"convert","op":{"create":{"input":"data","name":"create","points":[{"a":true,"bf":["embeddings","source_model","target_model"],"co":{"id":"POST /v1/convert","source":"openapi3","version":2},"g":{},"k":"http","li":{"assert":{"equal":{"source_model":{"from":"models","path":"sourceModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"target_model":{"from":"models","path":"targetModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}}},"vectors":{"count":1,"dimension":{"from":"models","path":"targetDim","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"path":"embeddings"}},"auth":"account","id":"account-convert","input":{"embeddings":{"from":"account-embed","path":"embeddings"},"source_model":{"from":"models","path":"sourceModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"target_model":{"from":"models","path":"targetModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}}}},"m":"POST","o":"/v1/convert","q":{},"r":{},"rs":{"kind":"json","media":"application/json"},"s":[{"lit":"v1"},{"lit":"convert"}],"t":{"req":"`reqdata`","res":"`body.data`"},"index$":0},{"a":true,"bf":["bridge_model","target_model","texts"],"co":{"id":"POST /v1/embed-bridge","source":"openapi3","version":2},"g":{},"k":"http","li":{"assert":{"equal":{"bridge_model":{"from":"models","path":"sourceModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"target_model":{"from":"models","path":"targetModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}}},"vectors":{"count":1,"dimension":{"from":"models","path":"targetDim","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"path":"embeddings"}},"auth":"account","id":"account-embed-bridge","input":{"bridge_model":{"from":"models","path":"sourceModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"target_model":{"from":"models","path":"targetModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"texts":["SDK live coverage test."]}},"m":"POST","o":"/v1/embed-bridge","q":{"$action":"bridge"},"r":{},"rs":{"kind":"json","media":"application/json"},"s":[{"lit":"v1"},{"lit":"embed-bridge"}],"t":{"req":"`reqdata`","res":"`body.data`"},"index$":1},{"a":true,"bf":["embeddings","source_model","target_model"],"co":{"id":"POST /v1/ephemeral/convert","source":"openapi3","version":2},"g":{},"k":"http","li":{"assert":{"equal":{"source_model":{"from":"models","path":"sourceModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"target_model":{"from":"models","path":"targetModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}}},"vectors":{"count":1,"dimension":{"from":"models","path":"targetDim","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"path":"embeddings"}},"auth":"issued","credential":{"from":"key","path":"key"},"id":"ephemeral-convert","input":{"embeddings":{"from":"ephemeral-embed","path":"embeddings"},"source_model":{"from":"models","path":"sourceModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"target_model":{"from":"models","path":"targetModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}}}},"m":"POST","o":"/v1/ephemeral/convert","q":{"$action":"ephemeral"},"r":{},"rs":{"kind":"json","media":"application/json"},"s":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"convert"}],"t":{"req":"`reqdata`","res":"`body.data`"},"index$":2},{"a":true,"bf":["bridge_model","target_model","texts"],"co":{"id":"POST /v1/ephemeral/embed-bridge","source":"openapi3","version":2},"g":{},"k":"http","li":{"assert":{"equal":{"bridge_model":{"from":"models","path":"sourceModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"target_model":{"from":"models","path":"targetModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}}},"vectors":{"count":1,"dimension":{"from":"models","path":"targetDim","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"path":"embeddings"}},"auth":"issued","credential":{"from":"key","path":"key"},"id":"ephemeral-embed-bridge","input":{"bridge_model":{"from":"models","path":"sourceModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"target_model":{"from":"models","path":"targetModel","related":{"foreign":"name","from":"models","local":"sourceModel","where":{"modelType":"embed"}},"where":{"modelType":"convert"}},"texts":["SDK live coverage test."]}},"m":"POST","o":"/v1/ephemeral/embed-bridge","q":{"$action":"ephemeral_bridge"},"r":{},"rs":{"kind":"json","media":"application/json"},"s":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"embed-bridge"}],"t":{"req":"`reqdata`","res":"`body.data`"},"index$":3}],"key$":"create"}},"relations":{"ancestors":[]},"key$":"convert","name__orig":"convert","Name":"Convert","name_":"convert","name-":"convert","NAME":"CONVERT","index$":0}, {"active":true,"entity":"convert","key$":"BasicConvertFlow","kind":"basic","name":"BasicConvertFlow","param":{},"step":[{"a":true,"d":{},"i":{"ref":"convert_ref01"},"m":{},"o":"create","s":[],"v":[],"index$":0}]}, 'Convert', {"POST /v1/convert":{"protocol":"http","requestBody":{"required":true,"content":{"application/json":{"schema":{"type":"object","required":["source_model","target_model","embeddings"],"properties":{"source_model":{"type":"string","description":"Model space the supplied vectors are currently in.","example":"alibaba-nlp-gte-large-en-v1.5","key$":"source_model"},"target_model":{"type":"string","description":"Model space to translate into. A converter must exist for the source/target pair — see listModels.","example":"nomic-embed-text-v1.5","key$":"target_model"},"embeddings":{"type":"array","description":"Vectors to translate. Each must match the source model's dimension exactly.","items":{"type":"array","description":"A single embedding vector.","items":{"type":"number","format":"float"},"x-ref":"#/components/schemas/Embedding"},"key$":"embeddings"}},"x-ref":"#/components/schemas/ConvertRequest","index$":1},"example":{"source_model":"alibaba-nlp-gte-large-en-v1.5","target_model":"nomic-embed-text-v1.5","embeddings":[[0.01,0.02,0.03]]}}},"x-ref":"#/components/requestBodies/ConvertRequest"},"parameters":[]},"POST /v1/embed-bridge":{"protocol":"http","requestBody":{"required":true,"content":{"application/json":{"schema":{"type":"object","required":["bridge_model","target_model","texts"],"properties":{"bridge_model":{"type":"string","description":"Embed model used to vectorise the text before translation.","example":"alibaba-nlp-gte-large-en-v1.5"},"target_model":{"type":"string","description":"Model space to translate into.","example":"nomic-embed-text-v1.5"},"texts":{"type":"array","description":"Texts to embed and translate.","items":{"type":"string"},"example":["hello world"]}},"x-ref":"#/components/schemas/EmbedBridgeRequest"},"example":{"bridge_model":"alibaba-nlp-gte-large-en-v1.5","target_model":"nomic-embed-text-v1.5","texts":["hello world"]}}},"x-ref":"#/components/requestBodies/EmbedBridgeRequest"},"parameters":[]},"POST /v1/ephemeral/convert":{"protocol":"http","requestBody":{"required":true,"content":{"application/json":{"schema":{"type":"object","required":["source_model","target_model","embeddings"],"properties":{"source_model":{"type":"string","description":"Model space the supplied vectors are currently in.","example":"alibaba-nlp-gte-large-en-v1.5","key$":"source_model"},"target_model":{"type":"string","description":"Model space to translate into. A converter must exist for the source/target pair — see listModels.","example":"nomic-embed-text-v1.5","key$":"target_model"},"embeddings":{"type":"array","description":"Vectors to translate. Each must match the source model's dimension exactly.","items":{"type":"array","description":"A single embedding vector.","items":{"type":"number","format":"float"},"x-ref":"#/components/schemas/Embedding"},"key$":"embeddings"}},"x-ref":"#/components/schemas/ConvertRequest","index$":1},"example":{"source_model":"alibaba-nlp-gte-large-en-v1.5","target_model":"nomic-embed-text-v1.5","embeddings":[[0.01,0.02,0.03]]}}},"x-ref":"#/components/requestBodies/ConvertRequest"},"parameters":[]},"POST /v1/ephemeral/embed-bridge":{"protocol":"http","requestBody":{"required":true,"content":{"application/json":{"schema":{"type":"object","required":["bridge_model","target_model","texts"],"properties":{"bridge_model":{"type":"string","description":"Embed model used to vectorise the text before translation.","example":"alibaba-nlp-gte-large-en-v1.5"},"target_model":{"type":"string","description":"Model space to translate into.","example":"nomic-embed-text-v1.5"},"texts":{"type":"array","description":"Texts to embed and translate.","items":{"type":"string"},"example":["hello world"]}},"x-ref":"#/components/schemas/EmbedBridgeRequest"},"example":{"bridge_model":"alibaba-nlp-gte-large-en-v1.5","target_model":"nomic-embed-text-v1.5","texts":["hello world"]}}},"x-ref":"#/components/requestBodies/EmbedBridgeRequest"},"parameters":[]}}, { strict: LIVE_STRICT, t })
    }
    const client = setup.client
    const struct = setup.struct

    const isempty = struct.isempty
    const select = struct.select


    // CREATE
    const convert_ref01_ent = client.Convert()
    let convert_ref01_data = setup.data.new.convert['convert_ref01']

    convert_ref01_data = (await convert_ref01_ent.create(convert_ref01_data)).data()
    assert(null != convert_ref01_data)


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
      '../../../../.sdk/test/entity/convert/ConvertTestData.json')

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
    ['convert01','convert02','convert03'],
    {
      '`$PACK`': ['', {
        '`$KEY`': '`$COPY`',
        '`$VAL`': ['`$FORMAT`', 'upper', '`$COPY`']
      }]
    })

  const env = envOverride({
    'UNIVEC_TEST_CONVERT_ENTID': idmap,
    'UNIVEC_TEST_LIVE': 'FALSE',
    'UNIVEC_TEST_EXPLAIN': 'FALSE',
    'UNIVEC_APIKEY': '',
  })

  idmap = env['UNIVEC_TEST_CONVERT_ENTID']

  const live = 'TRUE' === env.UNIVEC_TEST_LIVE
  const transport = createLiveTransport()
  if (live) {
    const rawIds = process.env['UNIVEC_TEST_CONVERT_ENTID']
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
  
