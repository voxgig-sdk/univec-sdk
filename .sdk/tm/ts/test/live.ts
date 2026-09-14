// Compatibility entry: run the same generated operation scenarios.
process.env.PROJECTENV_TEST_LIVE = 'TRUE'
require('./live.test')
