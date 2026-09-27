
import { test, describe } from 'node:test'
import { equal } from 'node:assert'


import { UnivecSDK } from '..'


describe('exists', async () => {

  test('test-mode', () => {
    const testsdk = UnivecSDK.test()
    equal(testsdk instanceof UnivecSDK, true,
      'UnivecSDK.test() must return a client synchronously')
  })

})
