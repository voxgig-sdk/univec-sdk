
const { test, describe } = require('node:test')
const { equal } = require('node:assert')


const { UnivecSDK } = require('..')


describe('exists', async () => {

  test('test-mode', async () => {
    const testsdk = await UnivecSDK.test()
    equal(null !== testsdk, true)
  })

})
