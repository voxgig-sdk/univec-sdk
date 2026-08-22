"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.config = void 0;
const TestFeature_1 = require("./feature/test/TestFeature");
const FEATURE_CLASS = {
    test: TestFeature_1.TestFeature,
};
class Config {
    makeFeature(fn) {
        const fc = FEATURE_CLASS[fn];
        const fi = new fc();
        // TODO: errors etc
        return fi;
    }
    // False for a feature added at runtime via options.extend (station's
    // adopt path) - the constructor uses this to skip makeFeature for names
    // no generated class backs.
    hasFeature(fn) {
        return null != FEATURE_CLASS[fn];
    }
    main = {
        name: 'Univec',
        slug: "univec",
        version: "0.0.1",
        target: "ts",
    };
    feature = {
        test: {
            "options": {
                "active": false
            }
        },
    };
    options = {
        base: "https://api.univec.ai",
        auth: {
            prefix: 'Bearer',
        },
        headers: {
            "content-type": "application/json"
        },
        entity: {
            convert: {},
            embed: {},
            ephemeral_key: {},
            model: {},
        }
    };
    entity = {
        "convert": {
            "fields": [
                {
                    "name": "bridge_model",
                    "req": true,
                    "short": "Embed model used to vectorise the text before translation.",
                    "type": "`$STRING`"
                },
                {
                    "name": "embeddings",
                    "req": true,
                    "short": "Translated vectors, in the target model's dimension.",
                    "type": "`$ARRAY`"
                },
                {
                    "name": "source_model",
                    "req": true,
                    "short": "Model space the supplied vectors are currently in.",
                    "type": "`$STRING`"
                },
                {
                    "name": "target_model",
                    "req": true,
                    "short": "Model space to translate into.",
                    "type": "`$STRING`"
                },
                {
                    "name": "texts",
                    "req": true,
                    "short": "Texts to embed and translate.",
                    "type": "`$ARRAY`"
                }
            ],
            "name": "convert",
            "op": {
                "create": {
                    "input": "data",
                    "name": "create",
                    "points": [
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/convert",
                            "parts": [
                                "v1",
                                "convert"
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            }
                        },
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/embed-bridge",
                            "parts": [
                                "v1",
                                "embed-bridge"
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            }
                        },
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/ephemeral/convert",
                            "parts": [
                                "v1",
                                "ephemeral",
                                "convert"
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            }
                        },
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/ephemeral/embed-bridge",
                            "parts": [
                                "v1",
                                "ephemeral",
                                "embed-bridge"
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            }
                        }
                    ]
                }
            },
            "relations": {
                "ancestors": []
            }
        },
        "embed": {
            "fields": [
                {
                    "name": "embeddings",
                    "req": true,
                    "short": "One vector per input text, in input order.",
                    "type": "`$ARRAY`"
                },
                {
                    "name": "model",
                    "req": true,
                    "short": "Model that produced the vectors.",
                    "type": "`$STRING`"
                },
                {
                    "name": "texts",
                    "req": true,
                    "short": "Texts to embed.",
                    "type": "`$ARRAY`"
                }
            ],
            "name": "embed",
            "op": {
                "create": {
                    "input": "data",
                    "name": "create",
                    "points": [
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/embed",
                            "parts": [
                                "v1",
                                "embed"
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            }
                        },
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/ephemeral/embed",
                            "parts": [
                                "v1",
                                "ephemeral",
                                "embed"
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            }
                        }
                    ]
                }
            },
            "relations": {
                "ancestors": []
            }
        },
        "ephemeral_key": {
            "fields": [
                {
                    "name": "dailyLimit",
                    "req": true,
                    "short": "Calls permitted per day.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "dailyUsed",
                    "req": true,
                    "short": "Calls already used today.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "key",
                    "req": true,
                    "short": "The ephemeral API key, prefixed `eph_`.",
                    "type": "`$STRING`"
                },
                {
                    "name": "resetsAt",
                    "req": true,
                    "short": "When the daily allowance resets.",
                    "type": "`$STRING`"
                }
            ],
            "name": "ephemeral_key",
            "op": {
                "create": {
                    "input": "data",
                    "name": "create",
                    "points": [
                        {
                            "args": {},
                            "kind": "http",
                            "method": "POST",
                            "orig": "/v1/ephemeral/key",
                            "parts": [
                                "v1",
                                "ephemeral",
                                "key"
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            }
                        }
                    ]
                }
            },
            "relations": {
                "ancestors": []
            }
        },
        "model": {
            "fields": [
                {
                    "name": "eval",
                    "short": "Retrieval-fidelity metrics for a convert model.",
                    "type": "`$OBJECT`"
                },
                {
                    "name": "executionProvider",
                    "short": "Hardware backend, e.g.",
                    "type": "`$STRING`"
                },
                {
                    "name": "modelCard",
                    "short": "Convert models only: training provenance and architecture detail.",
                    "type": "`$OBJECT`"
                },
                {
                    "name": "modelType",
                    "req": true,
                    "short": "`embed` for text-to-vector models, `convert` for space-translation models.",
                    "type": "`$STRING`"
                },
                {
                    "name": "name",
                    "req": true,
                    "short": "Model identifier used in requests.",
                    "type": "`$STRING`"
                },
                {
                    "name": "sequenceLen",
                    "short": "Embed models only: maximum input sequence length.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "sourceDim",
                    "short": "Convert models only: source vector dimension.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "sourceModel",
                    "short": "Convert models only: the source model space.",
                    "type": "`$STRING`"
                },
                {
                    "name": "targetDim",
                    "req": true,
                    "short": "Dimension of the produced vectors.",
                    "type": "`$INTEGER`"
                },
                {
                    "name": "targetModel",
                    "req": true,
                    "short": "The model space produced.",
                    "type": "`$STRING`"
                }
            ],
            "name": "model",
            "op": {
                "list": {
                    "input": "data",
                    "name": "list",
                    "points": [
                        {
                            "args": {},
                            "kind": "http",
                            "method": "GET",
                            "orig": "/v1/models",
                            "parts": [
                                "v1",
                                "models"
                            ],
                            "select": {},
                            "transform": {
                                "req": "`reqdata`",
                                "res": "`body.data`"
                            }
                        }
                    ]
                }
            },
            "relations": {
                "ancestors": []
            }
        }
    };
}
const config = new Config();
exports.config = config;
//# sourceMappingURL=Config.js.map