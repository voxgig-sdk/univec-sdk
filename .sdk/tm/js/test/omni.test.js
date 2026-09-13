// Smoke tests for the vendored omni runner itself: a runner that cannot
// FAIL a bad entry would turn every corpus suite vacuously green, so pin
// the failure paths, not just the happy one.

const { test, describe } = require('node:test')
const assert = require('node:assert')

const { SDK } = require('..')

const { OmniError, makeRunner } = require('./omni')


// A minimal in-memory spec: no fixture file, no OMNI block (lenient v0,
// like the shared corpus).
const SPEC = {
  primary: {
    smoke: {
      basic: {
        set: [
          { in: 1, out: 2 },
          { in: 41, out: 42 },
        ],
      },
      bad: {
        set: [
          { in: 1, out: 999 },
        ],
      },
      err: {
        set: [
          { in: 0, err: 'zero refused' },
        ],
      },
    },
  },
}

const inc = (n) => {
  if (0 === n) {
    throw new Error('smoke: zero refused')
  }
  return n + 1
}


describe('omni', () => {

  test('runset passes a correct subject', async () => {
    const runner = await makeRunner(SPEC, SDK.test())
    const R = await runner('smoke')
    await R.runset(R.spec.basic, inc)
  })


  test('runset FAILS a wrong result, with OmniError', async () => {
    const runner = await makeRunner(SPEC, SDK.test())
    const R = await runner('smoke')
    await assert.rejects(
      () => R.runset(R.spec.bad, inc),
      (err) => {
        assert.equal(err.name, 'OmniError')
        assert.ok(err instanceof OmniError)
        assert.match(err.message, /result mismatch/)
        return true
      })
  })


  test('an expected error is matched, an unexpected one fails', async () => {
    const runner = await makeRunner(SPEC, SDK.test())
    const R = await runner('smoke')

    await R.runset(R.spec.err, inc)

    await assert.rejects(
      () => R.runset(R.spec.err, (n) => n),
      (err) => {
        assert.equal(err.name, 'OmniError')
        assert.match(err.message, /expected error did not occur/)
        return true
      })
  })


  // js-resolver specific: the corpus throws error-shaped plain maps
  // (generated makeError rethrows the fixture's err verbatim), and the
  // vendored js omni port would read them as '[object Object]' (the
  // omni#54 errify fix is TypeScript-only at this tag). The resolver
  // rethrows them as real Errors — pin that, both matching and failing.
  test('a map-shaped throwable is matched by its message', async () => {
    const runner = await makeRunner(SPEC, SDK.test())
    const R = await runner('smoke')

    await R.runset(R.spec.err, () => { throw { message: 'zero refused' } })

    await assert.rejects(
      () => R.runset(R.spec.err, () => { throw { message: 'some other error' } }),
      (err) => {
        assert.equal(err.name, 'OmniError')
        assert.match(err.message, /error mismatch/)
        return true
      })
  })

})
