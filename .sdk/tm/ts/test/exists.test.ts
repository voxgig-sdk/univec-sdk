
import { test, describe } from 'node:test'
import { equal } from 'node:assert'


import { UnivecSDK } from '..'


describe('exists', async () => {

  test('test-mode', async () => {
    const testsdk = await UnivecSDK.test()
    equal(null !== testsdk, true)
  })

})
