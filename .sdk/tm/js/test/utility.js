/**
 * Shared utility functions for unit tests
 *
 * This module provides common helper functions used across unit tests
 * for creating test data, transformations, validations, and environment overrides.
 */

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
    'TRUE' === process.env.PROJECTNAME_TEST_LIVE ||
    'TRUE' === process.env.PROJECTNAME_TEST_OVERRIDE
  ) {
    Object.entries(m).map(n => {
      let envval = process.env[n[0]]
      if (null != envval) {
        envval = envval.trim()
        m[n[0]] = envval.startsWith('{') ? JSON.parse(envval) : envval
      }
    })
  }

  m.PROJECTNAME_TEST_EXPLAIN = process.env.PROJECTNAME_TEST_EXPLAIN || m.PROJECTNAME_TEST_EXPLAIN

  return m
}


module.exports = {
  makeStepData,
  makeMatch,
  makeReqdata,
  makeValid,
  makeCtrl,
  envOverride
}
