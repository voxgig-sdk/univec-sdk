

import Path from 'node:path'
import * as Fs from 'node:fs'

import { test, describe, afterEach } from 'node:test'
import assert from 'node:assert'
import { createLiveTransport } from '../../live-runner'
import { runLiveEntity } from '../../live-entity'


import { UnivecSDK, BaseFeature, stdutil } from '../../..'

import {
  envOverride,
  liveClientOptions,
  liveDelay,
  loadEnvLocal,
  makeCtrl,
  makeMatch,
  makeReqdata,
  makeStepData,
  makeValid,
  maybeSkipControl,
} from '../../utility'


// AFTER the imports on purpose: TypeScript hoists `import` above any
// statement in the emitted CommonJS, so a loader placed above them would
// run only after every imported module had already been evaluated - and
// anything reading process.env at module scope would miss these values.
loadEnvLocal(__dirname + '/../../../.env.local')


describe('ConvertEntity', async () => {

  // Per-test live pacing. Delay is read from sdk-test-control.json's
  // `test.live.delayMs`; only sleeps when UNIVEC_TEST_LIVE=TRUE.
  afterEach(liveDelay('UNIVEC_TEST_LIVE'))

  test('instance', async () => {
    const testsdk = UnivecSDK.test()
    const ent = testsdk.Convert()
    assert(null != ent)
  })


  test('basic', async (t) => {

    const live = 'TRUE' === process.env.UNIVEC_TEST_LIVE
    for (const op of ['create']) {
      if (!live && maybeSkipControl(t, 'entityOp', 'convert.' + op, live)) return
    }

    if (live) { t.skip('Covered by live operation scenarios'); return }
    const setup = basicSetup()
    if (setup.live) {
      return runLiveEntity(setup, {"active":true,"alias":{"field":{}},"fields":[{"active":true,"name":"bridge_model","req":true,"short":"Embed model used to vectorise the text before translation.","type":"`$STRING`","index$":0},{"active":true,"name":"embeddings","req":true,"short":"Translated vectors, in the target model's dimension.","type":"`$ARRAY`","index$":1},{"active":true,"name":"source_model","req":true,"short":"Model space the supplied vectors are currently in.","type":"`$STRING`","index$":2},{"active":true,"name":"target_model","req":true,"short":"Model space to translate into.","type":"`$STRING`","index$":3},{"active":true,"name":"texts","req":true,"short":"Texts to embed and translate.","type":"`$ARRAY`","index$":4}],"name":"convert","op":{"create":{"input":"data","name":"create","points":[{"active":true,"args":{},"contract":{"id":"POST /v1/convert","json":"{\"live\":{\"assert\":{\"equal\":{\"source_model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"target_model\":{\"from\":\"models\",\"path\":\"targetModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}}},\"vectors\":{\"count\":1,\"dimension\":{\"from\":\"models\",\"path\":\"targetDim\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"path\":\"embeddings\"}},\"auth\":\"account\",\"id\":\"account-convert\",\"input\":{\"embeddings\":{\"from\":\"account-embed\",\"path\":\"embeddings\"},\"source_model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"target_model\":{\"from\":\"models\",\"path\":\"targetModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}}}},\"operationId\":\"convertEmbedding\",\"parameters\":[],\"protocol\":\"http\",\"requestBody\":{\"content\":{\"application/json\":{\"example\":{\"embeddings\":[[0.01,0.02,0.03]],\"source_model\":\"alibaba-nlp-gte-large-en-v1.5\",\"target_model\":\"nomic-embed-text-v1.5\"},\"schema\":{\"properties\":{\"embeddings\":{\"description\":\"Vectors to translate. Each must match the source model's dimension exactly.\",\"items\":{\"description\":\"A single embedding vector.\",\"items\":{\"format\":\"float\",\"type\":\"number\"},\"type\":\"array\"},\"type\":\"array\"},\"source_model\":{\"description\":\"Model space the supplied vectors are currently in.\",\"example\":\"alibaba-nlp-gte-large-en-v1.5\",\"type\":\"string\"},\"target_model\":{\"description\":\"Model space to translate into. A converter must exist for the source/target pair — see listModels.\",\"example\":\"nomic-embed-text-v1.5\",\"type\":\"string\"}},\"required\":[\"source_model\",\"target_model\",\"embeddings\"],\"type\":\"object\"}}},\"required\":true},\"responses\":{\"200\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"data\":{\"properties\":{\"embeddings\":{\"description\":\"Translated vectors, in the target model's dimension.\",\"items\":{\"description\":\"A single embedding vector.\",\"items\":{\"format\":\"float\",\"type\":\"number\"},\"type\":\"array\"},\"type\":\"array\"},\"source_model\":{\"type\":\"string\"},\"target_model\":{\"type\":\"string\"}},\"required\":[\"embeddings\",\"source_model\",\"target_model\"],\"type\":\"object\"},\"success\":{\"type\":\"boolean\"}},\"required\":[\"success\",\"data\"],\"type\":\"object\"}}},\"description\":\"Translated embeddings\"},\"401\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"422\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"}},\"security\":[{\"bearerAuth\":[]}],\"securitySchemes\":{\"bearerAuth\":{\"description\":\"UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.\",\"scheme\":\"bearer\",\"type\":\"http\"}},\"securitySource\":\"definition\"}","source":"openapi3","version":1},"kind":"http","method":"POST","orig":"/v1/convert","segments":[{"lit":"v1"},{"lit":"convert"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"index$":0},{"active":true,"args":{},"contract":{"id":"POST /v1/embed-bridge","json":"{\"factSources\":{\"responses\":\"guide\"},\"live\":{\"assert\":{\"equal\":{\"bridge_model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"target_model\":{\"from\":\"models\",\"path\":\"targetModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}}},\"vectors\":{\"count\":1,\"dimension\":{\"from\":\"models\",\"path\":\"targetDim\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"path\":\"embeddings\"}},\"auth\":\"account\",\"id\":\"account-embed-bridge\",\"input\":{\"bridge_model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"target_model\":{\"from\":\"models\",\"path\":\"targetModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"texts\":[\"SDK live coverage test.\"]}},\"operationId\":\"embedBridge\",\"parameters\":[],\"protocol\":\"http\",\"requestBody\":{\"content\":{\"application/json\":{\"example\":{\"bridge_model\":\"alibaba-nlp-gte-large-en-v1.5\",\"target_model\":\"nomic-embed-text-v1.5\",\"texts\":[\"hello world\"]},\"schema\":{\"properties\":{\"bridge_model\":{\"description\":\"Embed model used to vectorise the text before translation.\",\"example\":\"alibaba-nlp-gte-large-en-v1.5\",\"type\":\"string\"},\"target_model\":{\"description\":\"Model space to translate into.\",\"example\":\"nomic-embed-text-v1.5\",\"type\":\"string\"},\"texts\":{\"description\":\"Texts to embed and translate.\",\"example\":[\"hello world\"],\"items\":{\"type\":\"string\"},\"type\":\"array\"}},\"required\":[\"bridge_model\",\"target_model\",\"texts\"],\"type\":\"object\"}}},\"required\":true},\"responses\":{\"200\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"data\":{\"properties\":{\"bridge_model\":{\"type\":\"string\"},\"embeddings\":{\"description\":\"Translated vectors, in the target model's dimension.\",\"items\":{\"description\":\"A single embedding vector.\",\"items\":{\"format\":\"float\",\"type\":\"number\"},\"type\":\"array\"},\"type\":\"array\"},\"model\":{\"type\":\"string\"},\"target_model\":{\"type\":\"string\"}},\"required\":[\"embeddings\",\"bridge_model\",\"target_model\"],\"type\":\"object\"},\"success\":{\"type\":\"boolean\"}},\"required\":[\"success\",\"data\"],\"type\":\"object\"}}},\"description\":\"Translated embeddings\"},\"401\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"422\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"}},\"security\":[{\"bearerAuth\":[]}],\"securitySchemes\":{\"bearerAuth\":{\"description\":\"UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.\",\"scheme\":\"bearer\",\"type\":\"http\"}},\"securitySource\":\"definition\"}","source":"openapi3","version":1},"kind":"http","method":"POST","orig":"/v1/embed-bridge","segments":[{"lit":"v1"},{"lit":"embed-bridge"}],"select":{"$action":"bridge"},"transform":{"req":"`reqdata`","res":"`body.data`"},"index$":1},{"active":true,"args":{},"contract":{"id":"POST /v1/ephemeral/convert","json":"{\"live\":{\"assert\":{\"equal\":{\"source_model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"target_model\":{\"from\":\"models\",\"path\":\"targetModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}}},\"vectors\":{\"count\":1,\"dimension\":{\"from\":\"models\",\"path\":\"targetDim\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"path\":\"embeddings\"}},\"auth\":\"issued\",\"credential\":{\"from\":\"key\",\"path\":\"key\"},\"id\":\"ephemeral-convert\",\"input\":{\"embeddings\":{\"from\":\"ephemeral-embed\",\"path\":\"embeddings\"},\"source_model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"target_model\":{\"from\":\"models\",\"path\":\"targetModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}}}},\"operationId\":\"convertEphemeralEmbedding\",\"parameters\":[],\"protocol\":\"http\",\"requestBody\":{\"content\":{\"application/json\":{\"example\":{\"embeddings\":[[0.01,0.02,0.03]],\"source_model\":\"alibaba-nlp-gte-large-en-v1.5\",\"target_model\":\"nomic-embed-text-v1.5\"},\"schema\":{\"properties\":{\"embeddings\":{\"description\":\"Vectors to translate. Each must match the source model's dimension exactly.\",\"items\":{\"description\":\"A single embedding vector.\",\"items\":{\"format\":\"float\",\"type\":\"number\"},\"type\":\"array\"},\"type\":\"array\"},\"source_model\":{\"description\":\"Model space the supplied vectors are currently in.\",\"example\":\"alibaba-nlp-gte-large-en-v1.5\",\"type\":\"string\"},\"target_model\":{\"description\":\"Model space to translate into. A converter must exist for the source/target pair — see listModels.\",\"example\":\"nomic-embed-text-v1.5\",\"type\":\"string\"}},\"required\":[\"source_model\",\"target_model\",\"embeddings\"],\"type\":\"object\"}}},\"required\":true},\"responses\":{\"200\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"data\":{\"properties\":{\"embeddings\":{\"description\":\"Translated vectors, in the target model's dimension.\",\"items\":{\"description\":\"A single embedding vector.\",\"items\":{\"format\":\"float\",\"type\":\"number\"},\"type\":\"array\"},\"type\":\"array\"},\"source_model\":{\"type\":\"string\"},\"target_model\":{\"type\":\"string\"}},\"required\":[\"embeddings\",\"source_model\",\"target_model\"],\"type\":\"object\"},\"success\":{\"type\":\"boolean\"}},\"required\":[\"success\",\"data\"],\"type\":\"object\"}}},\"description\":\"Translated embeddings\"},\"401\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"422\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"429\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"}},\"security\":[{\"bearerAuth\":[]}],\"securitySchemes\":{\"bearerAuth\":{\"description\":\"UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.\",\"scheme\":\"bearer\",\"type\":\"http\"}},\"securitySource\":\"definition\"}","source":"openapi3","version":1},"kind":"http","method":"POST","orig":"/v1/ephemeral/convert","segments":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"convert"}],"select":{"$action":"ephemeral"},"transform":{"req":"`reqdata`","res":"`body.data`"},"index$":2},{"active":true,"args":{},"contract":{"id":"POST /v1/ephemeral/embed-bridge","json":"{\"factSources\":{\"responses\":\"guide\"},\"live\":{\"assert\":{\"equal\":{\"bridge_model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"target_model\":{\"from\":\"models\",\"path\":\"targetModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}}},\"vectors\":{\"count\":1,\"dimension\":{\"from\":\"models\",\"path\":\"targetDim\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"path\":\"embeddings\"}},\"auth\":\"issued\",\"credential\":{\"from\":\"key\",\"path\":\"key\"},\"id\":\"ephemeral-embed-bridge\",\"input\":{\"bridge_model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"target_model\":{\"from\":\"models\",\"path\":\"targetModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"texts\":[\"SDK live coverage test.\"]}},\"operationId\":\"embedBridgeEphemeral\",\"parameters\":[],\"protocol\":\"http\",\"requestBody\":{\"content\":{\"application/json\":{\"example\":{\"bridge_model\":\"alibaba-nlp-gte-large-en-v1.5\",\"target_model\":\"nomic-embed-text-v1.5\",\"texts\":[\"hello world\"]},\"schema\":{\"properties\":{\"bridge_model\":{\"description\":\"Embed model used to vectorise the text before translation.\",\"example\":\"alibaba-nlp-gte-large-en-v1.5\",\"type\":\"string\"},\"target_model\":{\"description\":\"Model space to translate into.\",\"example\":\"nomic-embed-text-v1.5\",\"type\":\"string\"},\"texts\":{\"description\":\"Texts to embed and translate.\",\"example\":[\"hello world\"],\"items\":{\"type\":\"string\"},\"type\":\"array\"}},\"required\":[\"bridge_model\",\"target_model\",\"texts\"],\"type\":\"object\"}}},\"required\":true},\"responses\":{\"200\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"data\":{\"properties\":{\"bridge_model\":{\"type\":\"string\"},\"embeddings\":{\"description\":\"Translated vectors, in the target model's dimension.\",\"items\":{\"description\":\"A single embedding vector.\",\"items\":{\"format\":\"float\",\"type\":\"number\"},\"type\":\"array\"},\"type\":\"array\"},\"model\":{\"type\":\"string\"},\"target_model\":{\"type\":\"string\"}},\"required\":[\"embeddings\",\"bridge_model\",\"target_model\"],\"type\":\"object\"},\"success\":{\"type\":\"boolean\"}},\"required\":[\"success\",\"data\"],\"type\":\"object\"}}},\"description\":\"Translated embeddings\"},\"401\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"422\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"429\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"}},\"security\":[{\"bearerAuth\":[]}],\"securitySchemes\":{\"bearerAuth\":{\"description\":\"UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.\",\"scheme\":\"bearer\",\"type\":\"http\"}},\"securitySource\":\"definition\"}","source":"openapi3","version":1},"kind":"http","method":"POST","orig":"/v1/ephemeral/embed-bridge","segments":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"embed-bridge"}],"select":{"$action":"ephemeral_bridge"},"transform":{"req":"`reqdata`","res":"`body.data`"},"index$":3}],"key$":"create"}},"relations":{"ancestors":[]},"key$":"convert","name__orig":"convert","Name":"Convert","name_":"convert","name-":"convert","NAME":"CONVERT","index$":0}, {"active":true,"entity":"convert","key$":"BasicConvertFlow","kind":"basic","name":"BasicConvertFlow","param":{},"step":[{"active":true,"data":{},"input":{"ref":"convert_ref01"},"match":{},"op":"create","spec":[],"valid":[],"index$":0}]}, 'Convert')
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



function basicSetup(extra?: any) {
  // TODO: fix test def options
  const options: any = {} // null

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
      // 'extra || {}', not a bare 'extra': struct.merge returns UNDEFINED when the
      // last entry is undefined, and basicSetup is normally called with no
      // argument at all - so a bare 'extra' silently discarded the apikey
      // and server values above and handed the SDK undefined. Harmless
      // while there was nothing in that object; not harmless now.
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
  
