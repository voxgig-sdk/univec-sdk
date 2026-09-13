
const envlocal = __dirname + '/../../../.env.local'
require('dotenv').config({ quiet: true, path: [envlocal] })

const Path = require('node:path')
const Fs = require('node:fs')

const { test, describe, afterEach } = require('node:test')
const assert = require('node:assert')


const { ProjectNameSDK, BaseFeature, stdutil, config } = require('../../..')

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


describe('EntityNameEntity', async () => {

  // Per-test live pacing. Delay is read from sdk-test-control.json's
  // `test.live.delayMs`; only sleeps when PROJECTENV_TEST_LIVE=TRUE.
  afterEach(liveDelay('PROJECTENV_TEST_LIVE'))

  test('instance', async () => {
    const testsdk = ProjectNameSDK.test()
    const ent = testsdk.EntityName()
    assert(null != ent)
  })


  test('basic', async () => {
    // <[SLOT:basic]>
  })
})


// <[SLOT:basicSetup]>
