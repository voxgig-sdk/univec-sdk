// Compatibility entry: run the same generated operation scenarios.
process.env.UNIVEC_TEST_LIVE = 'TRUE'
require('./live.test')
