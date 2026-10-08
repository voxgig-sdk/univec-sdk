"use strict";
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
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_path_1 = __importDefault(require("node:path"));
const Fs = __importStar(require("node:fs"));
const node_test_1 = require("node:test");
const node_assert_1 = __importDefault(require("node:assert"));
const live_runner_1 = require("../../live-runner");
const live_entity_1 = require("../../live-entity");
const __1 = require("../../..");
const utility_1 = require("../../utility");
(0, utility_1.loadEnvLocal)(__dirname + '/../../../.env.local');
(0, node_test_1.describe)('EphemeralKeyEntity', async () => {
    // Per-test live pacing. Delay is read from sdk-test-control.json's
    // `test.live.delayMs`; only sleeps when UNIVEC_TEST_LIVE=TRUE.
    (0, node_test_1.afterEach)((0, utility_1.liveDelay)('UNIVEC_TEST_LIVE'));
    (0, node_test_1.test)('instance', async () => {
        const testsdk = __1.UnivecSDK.test();
        const ent = testsdk.EphemeralKey();
        (0, node_assert_1.default)(null != ent);
    });
    (0, node_test_1.test)('validate', async (t) => {
        if (null == __1.config.feature?.validate) {
            t.skip('feature not present in this SDK: validate');
            return;
        }
        const client = __1.UnivecSDK.test(undefined, { feature: { validate: { active: true } } });
        await node_assert_1.default.rejects(client.EphemeralKey().create({ "dailyLimit": "x", "dailyUsed": 1, "key": "x", "resetsAt": "x" }), (err) => 'validate_failed' === err.code);
    });
    (0, node_test_1.test)('basic', async (t) => {
        const live = 'TRUE' === process.env.UNIVEC_TEST_LIVE;
        for (const op of ['create']) {
            if (!live && (0, utility_1.maybeSkipControl)(t, 'entityOp', 'ephemeral_key.' + op, live))
                return;
        }
        if (live) {
            t.skip('Covered by live operation scenarios');
            return;
        }
        const setup = basicSetup();
        if (setup.live) {
            return (0, live_entity_1.runLiveEntity)(setup, { "active": true, "alias": { "field": {} }, "fields": { "dailyLimit": { "a": true, "h": "Daily Limit", "n": "dailyLimit", "r": true, "sh": "Calls permitted per day.", "t": "`$INTEGER`", "key$": "dailyLimit", "index$": 0 }, "dailyUsed": { "a": true, "h": "Daily Used", "n": "dailyUsed", "r": true, "sh": "Calls already used today.", "t": "`$INTEGER`", "key$": "dailyUsed", "index$": 1 }, "key": { "a": true, "h": "Key", "n": "key", "r": true, "sh": "The ephemeral API key, prefixed `eph_`.", "t": "`$STRING`", "key$": "key", "index$": 2 }, "resetsAt": { "a": true, "fo": "date-time", "h": "Resets At", "n": "resetsAt", "r": true, "sh": "When the daily allowance resets.", "t": "`$STRING`", "key$": "resetsAt", "index$": 3 } }, "name": "ephemeral_key", "op": { "create": { "input": "data", "name": "create", "points": [{ "a": true, "bf": false, "co": { "id": "POST /v1/ephemeral/key", "source": "openapi3", "version": 2 }, "g": {}, "k": "http", "li": { "assert": { "nonempty": ["key"] }, "auth": "public", "id": "key", "retention": "No deletion endpoint; issued key is subject to the service daily allowance" }, "m": "POST", "o": "/v1/ephemeral/key", "q": {}, "r": {}, "rs": { "kind": "json", "media": "application/json" }, "s": [{ "lit": "v1" }, { "lit": "ephemeral" }, { "lit": "key" }], "t": { "req": "`reqdata`", "res": "`body.data`" }, "index$": 0 }], "key$": "create" } }, "relations": { "ancestors": [] }, "key$": "ephemeral_key", "name__orig": "ephemeral_key", "Name": "EphemeralKey", "name_": "ephemeral_key", "name-": "ephemeral-key", "NAME": "EPHEMERAL_KEY", "index$": 2 }, { "active": true, "entity": "ephemeral_key", "key$": "BasicEphemeralKeyFlow", "kind": "basic", "name": "BasicEphemeralKeyFlow", "param": {}, "step": [{ "a": true, "d": {}, "i": { "ref": "ephemeral_key_ref01" }, "m": {}, "o": "create", "s": [], "v": [], "index$": 0 }] }, 'EphemeralKey', { "POST /v1/ephemeral/key": { "protocol": "http", "requestBody": { "required": false, "content": { "application/json": { "schema": { "type": "object", "additionalProperties": false, "index$": 1 }, "example": {} } } }, "parameters": [] } }, { strict: LIVE_STRICT, t });
        }
        const client = setup.client;
        const struct = setup.struct;
        const isempty = struct.isempty;
        const select = struct.select;
        // CREATE
        const ephemeral_key_ref01_ent = client.EphemeralKey();
        let ephemeral_key_ref01_data = setup.data.new.ephemeral_key['ephemeral_key_ref01'];
        ephemeral_key_ref01_data = (await ephemeral_key_ref01_ent.create(ephemeral_key_ref01_data)).data();
        (0, node_assert_1.default)(null != ephemeral_key_ref01_data);
    });
});
// main.kit.test.live.strict is true (the default is true): a live
// request that fails, or a live test missing an input it needs,
// fails the test.
// An account with no record for a test to read skips it either way.
const LIVE_STRICT = true;
function basicSetup(extra) {
    // TODO: fix test def options
    const options = {}; // null
    // TODO: needs test utility to resolve path
    const entityDataFile = node_path_1.default.resolve(__dirname, '../../../../.sdk/test/entity/ephemeral_key/EphemeralKeyTestData.json');
    // TODO: file ready util needed?
    const entityDataSource = Fs.readFileSync(entityDataFile).toString('utf8');
    // TODO: need a xlang JSON parse utility in voxgig/struct with better error msgs
    const entityData = JSON.parse(entityDataSource);
    options.entity = entityData.existing;
    let client = __1.UnivecSDK.test(options, extra);
    const struct = client.utility().struct;
    const merge = struct.merge;
    const transform = struct.transform;
    let idmap = transform(['ephemeral_key01', 'ephemeral_key02', 'ephemeral_key03'], {
        '`$PACK`': ['', {
                '`$KEY`': '`$COPY`',
                '`$VAL`': ['`$FORMAT`', 'upper', '`$COPY`']
            }]
    });
    const env = (0, utility_1.envOverride)({
        'UNIVEC_TEST_EPHEMERAL_KEY_ENTID': idmap,
        'UNIVEC_TEST_LIVE': 'FALSE',
        'UNIVEC_TEST_EXPLAIN': 'FALSE',
        'UNIVEC_APIKEY': '',
    });
    idmap = env['UNIVEC_TEST_EPHEMERAL_KEY_ENTID'];
    const live = 'TRUE' === env.UNIVEC_TEST_LIVE;
    const transport = (0, live_runner_1.createLiveTransport)();
    if (live) {
        const rawIds = process.env['UNIVEC_TEST_EPHEMERAL_KEY_ENTID'];
        idmap = rawIds && rawIds.trim() ? JSON.parse(rawIds) : {};
        if (!idmap || Array.isArray(idmap) || typeof idmap !== 'object') {
            throw new Error('Live ENTID must be a JSON object');
        }
        client = new __1.UnivecSDK(merge([
            // FIRST, so the generated fields below win: sdk-test-control.json's
            // test.client.options adds to the live client, it does not redirect it.
            (0, utility_1.liveClientOptions)(),
            {
                apikey: env.UNIVEC_APIKEY,
            },
            // 'extra || {}', not a bare 'extra': struct.merge returns UNDEFINED when the
            // last entry is undefined, and basicSetup is normally called with no
            // argument at all - so a bare 'extra' silently discarded the apikey
            // and server values above and handed the SDK undefined. Harmless
            // while there was nothing in that object; not harmless now.
            extra || {},
            { system: { fetch: transport.fetch } }
        ]));
    }
    const setup = {
        idmap,
        env,
        options,
        client,
        struct,
        data: entityData,
        explain: 'TRUE' === env.UNIVEC_TEST_EXPLAIN,
        live,
        transport,
        now: Date.now(),
    };
    return setup;
}
//# sourceMappingURL=EphemeralKeyEntity.test.js.map