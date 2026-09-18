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
// AFTER the imports on purpose: TypeScript hoists `import` above any
// statement in the emitted CommonJS, so a loader placed above them would
// run only after every imported module had already been evaluated - and
// anything reading process.env at module scope would miss these values.
(0, utility_1.loadEnvLocal)(__dirname + '/../../../.env.local');
(0, node_test_1.describe)('ConvertEntity', async () => {
    // Per-test live pacing. Delay is read from sdk-test-control.json's
    // `test.live.delayMs`; only sleeps when UNIVEC_TEST_LIVE=TRUE.
    (0, node_test_1.afterEach)((0, utility_1.liveDelay)('UNIVEC_TEST_LIVE'));
    (0, node_test_1.test)('instance', async () => {
        const testsdk = __1.UnivecSDK.test();
        const ent = testsdk.Convert();
        (0, node_assert_1.default)(null != ent);
    });
    (0, node_test_1.test)('basic', async (t) => {
        const live = 'TRUE' === process.env.UNIVEC_TEST_LIVE;
        for (const op of ['create']) {
            if (!live && (0, utility_1.maybeSkipControl)(t, 'entityOp', 'convert.' + op, live))
                return;
        }
        if (live) {
            t.skip('Covered by live operation scenarios');
            return;
        }
        const setup = basicSetup();
        if (setup.live) {
            return (0, live_entity_1.runLiveEntity)(setup, { "active": true, "alias": { "field": {} }, "fields": [{ "active": true, "name": "embeddings", "req": true, "short": "Translated vectors, in the target model's dimension.", "type": "`$ARRAY`", "index$": 0 }, { "active": true, "name": "source_model", "req": true, "short": "Model space the supplied vectors are currently in.", "type": "`$STRING`", "index$": 1 }, { "active": true, "name": "target_model", "req": true, "short": "Model space to translate into.", "type": "`$STRING`", "index$": 2 }], "name": "convert", "op": { "create": { "input": "data", "name": "create", "points": [{ "active": true, "args": {}, "contract": { "id": "POST /v1/convert" }, "kind": "http", "live": { "assert": { "equal": { "source_model": { "from": "models", "path": "sourceModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "target_model": { "from": "models", "path": "targetModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } } }, "vectors": { "count": 1, "dimension": { "from": "models", "path": "targetDim", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "path": "embeddings" } }, "auth": "account", "id": "account-convert", "input": { "embeddings": { "from": "account-embed", "path": "embeddings" }, "source_model": { "from": "models", "path": "sourceModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "target_model": { "from": "models", "path": "targetModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } } } }, "method": "POST", "orig": "/v1/convert", "segments": [{ "lit": "v1" }, { "lit": "convert" }], "select": {}, "transform": { "req": "`reqdata`", "res": "`body.data`" }, "index$": 0 }, { "active": true, "args": {}, "contract": { "id": "POST /v1/embed-bridge" }, "kind": "http", "live": { "assert": { "equal": { "bridge_model": { "from": "models", "path": "sourceModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "target_model": { "from": "models", "path": "targetModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } } }, "vectors": { "count": 1, "dimension": { "from": "models", "path": "targetDim", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "path": "embeddings" } }, "auth": "account", "id": "account-embed-bridge", "input": { "bridge_model": { "from": "models", "path": "sourceModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "target_model": { "from": "models", "path": "targetModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "texts": ["SDK live coverage test."] } }, "method": "POST", "orig": "/v1/embed-bridge", "segments": [{ "lit": "v1" }, { "lit": "embed-bridge" }], "select": { "$action": "bridge" }, "transform": { "req": "`reqdata`", "res": "`body.data`" }, "index$": 1 }, { "active": true, "args": {}, "contract": { "id": "POST /v1/ephemeral/convert" }, "kind": "http", "live": { "assert": { "equal": { "source_model": { "from": "models", "path": "sourceModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "target_model": { "from": "models", "path": "targetModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } } }, "vectors": { "count": 1, "dimension": { "from": "models", "path": "targetDim", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "path": "embeddings" } }, "auth": "issued", "credential": { "from": "key", "path": "key" }, "id": "ephemeral-convert", "input": { "embeddings": { "from": "ephemeral-embed", "path": "embeddings" }, "source_model": { "from": "models", "path": "sourceModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "target_model": { "from": "models", "path": "targetModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } } } }, "method": "POST", "orig": "/v1/ephemeral/convert", "segments": [{ "lit": "v1" }, { "lit": "ephemeral" }, { "lit": "convert" }], "select": { "$action": "ephemeral" }, "transform": { "req": "`reqdata`", "res": "`body.data`" }, "index$": 2 }, { "active": true, "args": {}, "contract": { "id": "POST /v1/ephemeral/embed-bridge" }, "kind": "http", "live": { "assert": { "equal": { "bridge_model": { "from": "models", "path": "sourceModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "target_model": { "from": "models", "path": "targetModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } } }, "vectors": { "count": 1, "dimension": { "from": "models", "path": "targetDim", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "path": "embeddings" } }, "auth": "issued", "credential": { "from": "key", "path": "key" }, "id": "ephemeral-embed-bridge", "input": { "bridge_model": { "from": "models", "path": "sourceModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "target_model": { "from": "models", "path": "targetModel", "related": { "foreign": "name", "from": "models", "local": "sourceModel", "where": { "modelType": "embed" } }, "where": { "modelType": "convert" } }, "texts": ["SDK live coverage test."] } }, "method": "POST", "orig": "/v1/ephemeral/embed-bridge", "segments": [{ "lit": "v1" }, { "lit": "ephemeral" }, { "lit": "embed-bridge" }], "select": { "$action": "ephemeral_bridge" }, "transform": { "req": "`reqdata`", "res": "`body.data`" }, "index$": 3 }], "key$": "create" } }, "relations": { "ancestors": [] }, "key$": "convert", "name__orig": "convert", "Name": "Convert", "name_": "convert", "name-": "convert", "NAME": "CONVERT", "index$": 0 }, { "active": true, "entity": "convert", "key$": "BasicConvertFlow", "kind": "basic", "name": "BasicConvertFlow", "param": {}, "step": [{ "active": true, "data": {}, "input": { "ref": "convert_ref01" }, "match": {}, "op": "create", "spec": [], "valid": [], "index$": 0 }] }, 'Convert');
        }
        const client = setup.client;
        const struct = setup.struct;
        const isempty = struct.isempty;
        const select = struct.select;
        // CREATE
        const convert_ref01_ent = client.Convert();
        let convert_ref01_data = setup.data.new.convert['convert_ref01'];
        convert_ref01_data = (await convert_ref01_ent.create(convert_ref01_data)).data();
        (0, node_assert_1.default)(null != convert_ref01_data);
    });
});
function basicSetup(extra) {
    // TODO: fix test def options
    const options = {}; // null
    // TODO: needs test utility to resolve path
    const entityDataFile = node_path_1.default.resolve(__dirname, '../../../../.sdk/test/entity/convert/ConvertTestData.json');
    // TODO: file ready util needed?
    const entityDataSource = Fs.readFileSync(entityDataFile).toString('utf8');
    // TODO: need a xlang JSON parse utility in voxgig/struct with better error msgs
    const entityData = JSON.parse(entityDataSource);
    options.entity = entityData.existing;
    let client = __1.UnivecSDK.test(options, extra);
    const struct = client.utility().struct;
    const merge = struct.merge;
    const transform = struct.transform;
    let idmap = transform(['convert01', 'convert02', 'convert03'], {
        '`$PACK`': ['', {
                '`$KEY`': '`$COPY`',
                '`$VAL`': ['`$FORMAT`', 'upper', '`$COPY`']
            }]
    });
    const env = (0, utility_1.envOverride)({
        'UNIVEC_TEST_CONVERT_ENTID': idmap,
        'UNIVEC_TEST_LIVE': 'FALSE',
        'UNIVEC_TEST_EXPLAIN': 'FALSE',
        'UNIVEC_APIKEY': '',
    });
    idmap = env['UNIVEC_TEST_CONVERT_ENTID'];
    const live = 'TRUE' === env.UNIVEC_TEST_LIVE;
    const transport = (0, live_runner_1.createLiveTransport)();
    if (live) {
        const rawIds = process.env['UNIVEC_TEST_CONVERT_ENTID'];
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
//# sourceMappingURL=ConvertEntity.test.js.map