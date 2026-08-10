
const envlocal = __dirname + '/../../../.env.local'
require('dotenv').config({ quiet: true, path: [envlocal] })

const { test, describe } = require('node:test')
const assert = require('node:assert')


const { ProjectNameSDK } = require('../../..')

const {
  envOverride,
} = require('../../utility')


describe('EntityNameDirect', async () => {

  test('direct-exists', async () => {
    const sdk = new ProjectNameSDK({
      // Concrete base: a live construction must satisfy any server
      // variables a templated base URL declares; overriding base with a
      // literal (as the direct flow tests do) sidesteps the requirement.
      base: 'http://localhost:8080',
      system: { fetch: async () => ({}) }
    })
    assert('function' === typeof sdk.direct)
    assert('function' === typeof sdk.prepare)
  })

  // <[SLOT:direct]>
})


// <[SLOT:directSetup]>
