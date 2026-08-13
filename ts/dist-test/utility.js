"use strict";
/**
 * Shared utility functions for unit tests
 *
 * This module provides common helper functions used across unit tests
 * for creating test data, transformations, validations, and environment overrides.
 */
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.makeStepData = makeStepData;
exports.makeMatch = makeMatch;
exports.makeReqdata = makeReqdata;
exports.makeValid = makeValid;
exports.makeCtrl = makeCtrl;
exports.envOverride = envOverride;
exports.loadTestControl = loadTestControl;
exports.isControlSkipped = isControlSkipped;
exports.maybeSkipControl = maybeSkipControl;
exports.skipIfMissingIds = skipIfMissingIds;
exports.liveDelayMs = liveDelayMs;
exports.liveDelay = liveDelay;
const Fs = __importStar(require("node:fs"));
const Path = __importStar(require("node:path"));
// Creates a new step data structure within the data model
function makeStepData(dm, stepname) {
    dm.s[stepname] = {
        entity: undefined,
        match: undefined,
        reqdata: undefined,
        resdata: undefined,
    };
    return dm.s[stepname];
}
// Transforms and creates a match object using the provided transform function
function makeMatch(dm, transform, match) {
    return transform({}, match, { meta: { dm } });
}
// Transforms and creates request data using the provided transform function
function makeReqdata(dm, transform, data) {
    return transform({}, data, { meta: { dm } });
}
// Validates data against validation rules and returns the result
function makeValid(dm, validate, data, valid) {
    valid["`$OPEN`"] = true;
    return validate(data, valid, { meta: { '`$EXISTS`': true, dm } });
}
// Creates a control object for test explanations when enabled
function makeCtrl(explain) {
    return explain ? { explain: {} } : undefined;
}
// CLAUDE: add a full stop to each function comment
// Overrides configuration values with environment variables if available
function envOverride(m) {
    if ('TRUE' === process.env.UNIVEC_TEST_LIVE ||
        'TRUE' === process.env.UNIVEC_TEST_OVERRIDE) {
        Object.entries(m).map(n => {
            let envval = process.env[n[0]];
            if (null != envval) {
                envval = envval.trim();
                m[n[0]] = envval.startsWith('{') ? JSON.parse(envval) : envval;
            }
        });
    }
    m.UNIVEC_TEST_EXPLAIN = process.env.UNIVEC_TEST_EXPLAIN || m.UNIVEC_TEST_EXPLAIN;
    return m;
}
let _testControlCache = null;
function loadTestControl() {
    if (_testControlCache)
        return _testControlCache;
    const ctrlPath = Path.resolve(__dirname, '../test/sdk-test-control.json');
    try {
        _testControlCache = JSON.parse(Fs.readFileSync(ctrlPath, 'utf8'));
    }
    catch {
        _testControlCache = {
            version: 1,
            test: { skip: { live: { direct: [], entityOp: [] }, unit: { direct: [], entityOp: [] } } }
        };
    }
    return _testControlCache;
}
// Returns the skip decision for a given test name from sdk-test-control.json.
// `kind` is 'direct' (matches by `test` field) or 'entityOp' (matches by
// `entity` + `op`). `mode` is 'live' or 'unit'.
function isControlSkipped(kind, name, mode) {
    const ctrl = loadTestControl();
    const list = ctrl?.test?.skip?.[mode]?.[kind] ?? [];
    for (const e of list) {
        if (kind === 'direct' && e?.test === name) {
            return { skip: true, reason: e.reason };
        }
        if (kind === 'entityOp') {
            const key = (e?.entity ?? '') + '.' + (e?.op ?? '');
            if (key === name)
                return { skip: true, reason: e.reason };
        }
    }
    return { skip: false };
}
// Skips the current test if sdk-test-control.json lists it. Returns true
// when skipped (caller should `return` immediately).
function maybeSkipControl(t, kind, name, live) {
    const decision = isControlSkipped(kind, name, live ? 'live' : 'unit');
    if (decision.skip) {
        t.skip(decision.reason || 'skipped via sdk-test-control.json');
        return true;
    }
    return false;
}
// Skips the current live test when required idmap keys aren't supplied.
// Generated tests call this when they would otherwise pass `undefined`
// values into a path/query param and 4xx the request.
function skipIfMissingIds(t, setup, requiredKeys) {
    if (!setup.live)
        return false;
    const missing = requiredKeys.filter(k => null == setup.idmap?.[k]);
    if (missing.length > 0) {
        t.skip(`live test needs ${missing.join(', ')} via *_ENTID env var (synthetic IDs only)`);
        return true;
    }
    return false;
}
// Per-test live pacing delay (ms). Read from sdk-test-control.json
// `test.live.delayMs`; defaults to 500ms if absent or invalid.
function liveDelayMs() {
    const ctrl = loadTestControl();
    const v = ctrl?.test?.live?.delayMs;
    return ('number' === typeof v && v >= 0) ? v : 500;
}
// afterEach hook helper for live pacing. Generated tests register this
// via `afterEach(liveDelay(<envVar>))`; it sleeps `liveDelayMs()` only
// when the SDK's *_TEST_LIVE env var is set.
function liveDelay(liveEnvVar) {
    return async () => {
        if ('TRUE' === process.env[liveEnvVar]) {
            await new Promise(r => setTimeout(r, liveDelayMs()));
        }
    };
}
//# sourceMappingURL=utility.js.map