

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


describe('EmbedEntity', async () => {

  // Per-test live pacing. Delay is read from sdk-test-control.json's
  // `test.live.delayMs`; only sleeps when UNIVEC_TEST_LIVE=TRUE.
  afterEach(liveDelay('UNIVEC_TEST_LIVE'))

  test('instance', async () => {
    const testsdk = UnivecSDK.test()
    const ent = testsdk.Embed()
    assert(null != ent)
  })


  test('basic', async (t) => {

    const live = 'TRUE' === process.env.UNIVEC_TEST_LIVE
    for (const op of ['create']) {
      if (!live && maybeSkipControl(t, 'entityOp', 'embed.' + op, live)) return
    }

    if (live) { t.skip('Covered by live operation scenarios'); return }
    const setup = basicSetup()
    if (setup.live) {
      return runLiveEntity(setup, {"active":true,"alias":{"field":{}},"fields":[{"active":true,"name":"embeddings","req":true,"short":"One vector per input text, in input order.","type":"`$ARRAY`","index$":0},{"active":true,"name":"model","req":true,"short":"Model that produced the vectors.","type":"`$STRING`","index$":1},{"active":true,"name":"texts","req":true,"short":"Texts to embed.","type":"`$ARRAY`","index$":2}],"name":"embed","op":{"create":{"input":"data","name":"create","points":[{"active":true,"args":{},"contract":{"id":"POST /v1/embed","json":"{\"live\":{\"assert\":{\"equal\":{\"model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}}},\"vectors\":{\"count\":1,\"dimension\":{\"from\":\"models\",\"path\":\"sourceDim\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"path\":\"embeddings\"}},\"auth\":\"account\",\"id\":\"account-embed\",\"input\":{\"model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"texts\":[\"SDK live coverage test.\"]}},\"operationId\":\"createEmbedding\",\"parameters\":[],\"protocol\":\"http\",\"requestBody\":{\"content\":{\"application/json\":{\"example\":{\"model\":\"baai-bge-base-en-v1.5\",\"texts\":[\"hello world\"]},\"schema\":{\"properties\":{\"model\":{\"description\":\"Name of an embed model, as returned by listModels.\",\"example\":\"baai-bge-base-en-v1.5\",\"type\":\"string\"},\"texts\":{\"description\":\"Texts to embed. One vector is returned per text, in order.\",\"example\":[\"hello world\"],\"items\":{\"type\":\"string\"},\"type\":\"array\"}},\"required\":[\"model\",\"texts\"],\"type\":\"object\"}}},\"required\":true},\"responses\":{\"200\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"data\":{\"properties\":{\"embeddings\":{\"description\":\"One vector per input text, in input order.\",\"items\":{\"description\":\"A single embedding vector.\",\"items\":{\"format\":\"float\",\"type\":\"number\"},\"type\":\"array\"},\"type\":\"array\"},\"model\":{\"description\":\"Model that produced the vectors.\",\"type\":\"string\"}},\"required\":[\"embeddings\",\"model\"],\"type\":\"object\"},\"success\":{\"type\":\"boolean\"}},\"required\":[\"success\",\"data\"],\"type\":\"object\"}}},\"description\":\"Generated embeddings\"},\"401\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"422\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"}},\"security\":[{\"bearerAuth\":[]}],\"securitySchemes\":{\"bearerAuth\":{\"description\":\"UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.\",\"scheme\":\"bearer\",\"type\":\"http\"}},\"securitySource\":\"definition\"}","source":"openapi3","version":1},"kind":"http","method":"POST","orig":"/v1/embed","segments":[{"lit":"v1"},{"lit":"embed"}],"select":{},"transform":{"req":"`reqdata`","res":"`body.data`"},"index$":0},{"active":true,"args":{},"contract":{"id":"POST /v1/ephemeral/embed","json":"{\"live\":{\"assert\":{\"equal\":{\"model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}}},\"vectors\":{\"count\":1,\"dimension\":{\"from\":\"models\",\"path\":\"sourceDim\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"path\":\"embeddings\"}},\"auth\":\"issued\",\"credential\":{\"from\":\"key\",\"path\":\"key\"},\"id\":\"ephemeral-embed\",\"input\":{\"model\":{\"from\":\"models\",\"path\":\"sourceModel\",\"related\":{\"foreign\":\"name\",\"from\":\"models\",\"local\":\"sourceModel\",\"where\":{\"modelType\":\"embed\"}},\"where\":{\"modelType\":\"convert\"}},\"texts\":[\"SDK live coverage test.\"]}},\"operationId\":\"createEphemeralEmbedding\",\"parameters\":[],\"protocol\":\"http\",\"requestBody\":{\"content\":{\"application/json\":{\"example\":{\"model\":\"baai-bge-base-en-v1.5\",\"texts\":[\"hello world\"]},\"schema\":{\"properties\":{\"model\":{\"description\":\"Name of an embed model, as returned by listModels.\",\"example\":\"baai-bge-base-en-v1.5\",\"type\":\"string\"},\"texts\":{\"description\":\"Texts to embed. One vector is returned per text, in order.\",\"example\":[\"hello world\"],\"items\":{\"type\":\"string\"},\"type\":\"array\"}},\"required\":[\"model\",\"texts\"],\"type\":\"object\"}}},\"required\":true},\"responses\":{\"200\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"data\":{\"properties\":{\"embeddings\":{\"description\":\"One vector per input text, in input order.\",\"items\":{\"description\":\"A single embedding vector.\",\"items\":{\"format\":\"float\",\"type\":\"number\"},\"type\":\"array\"},\"type\":\"array\"},\"model\":{\"description\":\"Model that produced the vectors.\",\"type\":\"string\"}},\"required\":[\"embeddings\",\"model\"],\"type\":\"object\"},\"success\":{\"type\":\"boolean\"}},\"required\":[\"success\",\"data\"],\"type\":\"object\"}}},\"description\":\"Generated embeddings\"},\"401\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"422\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"},\"429\":{\"content\":{\"application/json\":{\"schema\":{\"properties\":{\"error\":{\"properties\":{\"message\":{\"description\":\"Human-readable error detail.\",\"type\":\"string\"}},\"required\":[\"message\"],\"type\":\"object\"},\"success\":{\"description\":\"Always false on an error.\",\"type\":\"boolean\"}},\"required\":[\"success\",\"error\"],\"type\":\"object\"}}},\"description\":\"Error\"}},\"security\":[{\"bearerAuth\":[]}],\"securitySchemes\":{\"bearerAuth\":{\"description\":\"UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.\",\"scheme\":\"bearer\",\"type\":\"http\"}},\"securitySource\":\"definition\"}","source":"openapi3","version":1},"kind":"http","method":"POST","orig":"/v1/ephemeral/embed","segments":[{"lit":"v1"},{"lit":"ephemeral"},{"lit":"embed"}],"select":{"$action":"ephemeral"},"transform":{"req":"`reqdata`","res":"`body.data`"},"index$":1}],"key$":"create"}},"relations":{"ancestors":[]},"key$":"embed","name__orig":"embed","Name":"Embed","name_":"embed","name-":"embed","NAME":"EMBED","index$":1}, {"active":true,"entity":"embed","key$":"BasicEmbedFlow","kind":"basic","name":"BasicEmbedFlow","param":{},"step":[{"active":true,"data":{},"input":{"ref":"embed_ref01"},"match":{},"op":"create","spec":[],"valid":[]}]}, 'Embed')
    }
    const client = setup.client
    const struct = setup.struct

    const isempty = struct.isempty
    const select = struct.select


    // CREATE
    const embed_ref01_ent = client.Embed()
    let embed_ref01_data = setup.data.new.embed['embed_ref01']

    embed_ref01_data = (await embed_ref01_ent.create(embed_ref01_data)).data()
    assert(null != embed_ref01_data)


  })
})



function basicSetup(extra?: any) {
  // TODO: fix test def options
  const options: any = {} // null

  // TODO: needs test utility to resolve path
  const entityDataFile =
    Path.resolve(__dirname, 
      '../../../../.sdk/test/entity/embed/EmbedTestData.json')

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
    ['embed01','embed02','embed03'],
    {
      '`$PACK`': ['', {
        '`$KEY`': '`$COPY`',
        '`$VAL`': ['`$FORMAT`', 'upper', '`$COPY`']
      }]
    })

  const env = envOverride({
    'UNIVEC_TEST_EMBED_ENTID': idmap,
    'UNIVEC_TEST_LIVE': 'FALSE',
    'UNIVEC_TEST_EXPLAIN': 'FALSE',
    'UNIVEC_APIKEY': '',
  })

  idmap = env['UNIVEC_TEST_EMBED_ENTID']

  const live = 'TRUE' === env.UNIVEC_TEST_LIVE

  const transport = createLiveTransport()
  if (live) {
    const rawIds = process.env['UNIVEC_TEST_EMBED_ENTID']
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
  
