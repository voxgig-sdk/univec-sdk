

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


loadEnvLocal(__dirname + '/../../../.env.local')


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

    const live = 'TRUE' === process.env.UNIVEC_TEST_LIVE
    for (const op of ['list']) {
      if (!live && maybeSkipControl(t, 'entityOp', 'model.' + op, live)) return
    }

    if (live) { t.skip('Covered by live operation scenarios'); return }
    const setup = basicSetup()
    if (setup.live) {
      return runLiveEntity(setup, {"active":true,"alias":{"field":{}},"fields":{"eval":{"a":true,"h":"Eval","n":"eval","r":false,"sh":"Retrieval-fidelity metrics for a convert model.","t":"`$OBJECT`","key$":"eval","index$":0},"executionProvider":{"a":true,"h":"Execution Provider","n":"executionProvider","r":false,"sh":"Hardware backend, e.g.","t":"`$STRING`","key$":"executionProvider","index$":1},"modelCard":{"a":true,"h":"Model Card","n":"modelCard","r":false,"sh":"Convert models only: training provenance and architecture detail.","t":"`$OBJECT`","key$":"modelCard","index$":2},"modelType":{"a":true,"h":"Model Type","n":"modelType","r":true,"sh":"`embed` for text-to-vector models, `convert` for space-translation models.","t":"`$STRING`","key$":"modelType","index$":3},"name":{"a":true,"h":"Name","n":"name","r":true,"sh":"Model identifier used in requests.","t":"`$STRING`","key$":"name","index$":4},"sequenceLen":{"a":true,"h":"Sequence Len","n":"sequenceLen","r":false,"sh":"Embed models only: maximum input sequence length.","t":"`$INTEGER`","key$":"sequenceLen","index$":5},"sourceDim":{"a":true,"h":"Source Dim","n":"sourceDim","r":false,"sh":"Convert models only: source vector dimension.","t":"`$INTEGER`","key$":"sourceDim","index$":6},"sourceModel":{"a":true,"h":"Source Model","n":"sourceModel","r":false,"sh":"Convert models only: the source model space.","t":"`$STRING`","key$":"sourceModel","index$":7},"targetDim":{"a":true,"h":"Target Dim","n":"targetDim","r":true,"sh":"Dimension of the produced vectors.","t":"`$INTEGER`","key$":"targetDim","index$":8},"targetModel":{"a":true,"h":"Target Model","n":"targetModel","r":true,"sh":"The model space produced.","t":"`$STRING`","key$":"targetModel","index$":9}},"name":"model","op":{"list":{"input":"data","name":"list","points":[{"a":true,"co":{"id":"GET /v1/models","source":"openapi3","version":2},"g":{},"k":"http","li":{"assert":{"nonempty":[""]},"auth":"public","id":"models"},"m":"GET","o":"/v1/models","q":{},"r":{},"s":[{"lit":"v1"},{"lit":"models"}],"t":{"req":"`reqdata`","res":"`body.data`"},"index$":0}],"key$":"list"}},"relations":{"ancestors":[]},"key$":"model","name__orig":"model","Name":"Model","name_":"model","name-":"model","NAME":"MODEL","index$":3}, {"active":true,"entity":"model","key$":"BasicModelFlow","kind":"basic","name":"BasicModelFlow","param":{},"step":[{"a":true,"d":{},"i":{},"m":{},"o":"list","s":[],"v":[{"apply":"ItemExists","def":{"ref":"model_ref01"}}],"index$":0}]}, 'Model', {"GET /v1/models":{"protocol":"http","parameters":[]}})
    }
    const client = setup.client
    const struct = setup.struct

    const isempty = struct.isempty
    const select = struct.select

    let model_ref01_data = Object.values(setup.data.existing.model)[0] as any

    // LIST
    const model_ref01_ent = client.Model()
    const model_ref01_match: any = {}

    const model_ref01_list = (await model_ref01_ent.list(model_ref01_match)).map((e: any) => e.data())


  })
})



function basicSetup(extra?: any) {
  // TODO: fix test def options
  const options: any = {} // null

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
  
