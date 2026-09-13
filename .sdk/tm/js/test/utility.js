/**
 * Shared utility functions for unit tests
 *
 * This module provides common helper functions used across unit tests
 * for creating test data, transformations, validations, and environment overrides.
 */

const Fs = require('node:fs')
const Path = require('node:path')


// Creates a new step data structure within the data model
function makeStepData(dm, stepname) {
  dm.s[stepname] = {
    entity: undefined,
    match: undefined,
    reqdata: undefined,
    resdata: undefined,
  }
  return dm.s[stepname]
}


// Transforms and creates a match object using the provided transform function
function makeMatch(dm, transform, match) {
  return transform({}, match, { meta: { dm } })
}


// Transforms and creates request data using the provided transform function
function makeReqdata(dm, transform, data) {
  return transform({}, data, { meta: { dm } })
}


// Validates data against validation rules and returns the result
function makeValid(dm, validate, data, valid) {
  valid["`$OPEN`"] = true
  return validate(data, valid, { meta: { '`$EXISTS`': true, dm } })
}


// Creates a control object for test explanations when enabled
function makeCtrl(explain) {
  return explain ? { explain: {} } : undefined
}

// Overrides configuration values with environment variables if available
function envOverride(m) {
  if (
    'TRUE' === process.env.PROJECTENV_TEST_LIVE ||
    'TRUE' === process.env.PROJECTENV_TEST_OVERRIDE
  ) {
    Object.entries(m).map(n => {
      let envval = process.env[n[0]]
      if (null != envval) {
        envval = envval.trim()
        m[n[0]] = envval.startsWith('{') ? JSON.parse(envval) : envval
      }
    })
  }

  m.PROJECTENV_TEST_EXPLAIN = process.env.PROJECTENV_TEST_EXPLAIN || m.PROJECTENV_TEST_EXPLAIN

  return m
}


// Loads sdk-test-control.json (cached). Returns an empty-skip object if
// the file is missing or unparsable so tests never crash on a bad config.
let _testControlCache = null

function loadTestControl() {
  if (_testControlCache) return _testControlCache
  const ctrlPath = Path.resolve(__dirname, '../test/sdk-test-control.json')
  try {
    _testControlCache = JSON.parse(Fs.readFileSync(ctrlPath, 'utf8'))
  }
  catch {
    _testControlCache = {
      version: 1,
      test: { skip: { live: { direct: [], entityOp: [] }, unit: { direct: [], entityOp: [] } } }
    }
  }
  return _testControlCache
}


// Extra SDK options every LIVE client is constructed with, read from
// sdk-test-control.json `test.client.options`.
//
// The generated live client knows two things: the base URL (from the spec)
// and the credential (from the environment). Everything else about how a
// particular API wants to be talked to - which features to switch on, and
// with what settings - is a property of THAT API, known to the project and
// to nothing in the toolchain. So it lives in the file the project owns and
// describes, where it can be read and reviewed. Secrets still come from the
// environment (the providers this block names read them).
//
// Merged UNDER the generated fields, so the suite's own base/apikey/server
// values win - this adds to the live client, it does not redirect it.
//
// That contract is enforced HERE rather than left to each merge site: the
// generated object only names a field when the model calls for one, so a
// `base` in this block would face no competing value and would silently
// redirect the whole suite - credential included - to another host. The
// reserved fields are stripped once, where the block is read, so every
// caller gets the same guarantee whether or not it happens to emit them.
const LIVE_RESERVED = ['base', 'prefix', 'suffix', 'server', 'apikey', 'secret']

function liveClientOptions() {
  const ctrl = loadTestControl()
  const opts = ctrl && ctrl.test && ctrl.test.client && ctrl.test.client.options

  if (null == opts || 'object' !== typeof opts) {
    return {}
  }

  const out = {}
  for (const key of Object.keys(opts)) {
    if (!LIVE_RESERVED.includes(key)) {
      out[key] = opts[key]
    }
  }

  return out
}


// Per-test live pacing delay (ms). Read from sdk-test-control.json
// `test.live.delayMs`; defaults to 500ms if absent or invalid.
function liveDelayMs() {
  const ctrl = loadTestControl()
  const v = ctrl && ctrl.test && ctrl.test.live && ctrl.test.live.delayMs
  return ('number' === typeof v && v >= 0) ? v : 500
}



// afterEach hook helper for live pacing. Generated tests register this via
// `afterEach(liveDelay(<envVar>))`; it sleeps `liveDelayMs()` only when the
// SDK's *_TEST_LIVE env var is set.
function liveDelay(liveEnvVar) {
  return async () => {
    if ('TRUE' === process.env[liveEnvVar]) {
      await new Promise(r => setTimeout(r, liveDelayMs()))
    }
  }
}

module.exports = {
  makeStepData,
  makeMatch,
  makeReqdata,
  makeValid,
  makeCtrl,
  envOverride,
  loadTestControl,
  liveClientOptions,
  liveDelayMs,
  liveDelay
}
