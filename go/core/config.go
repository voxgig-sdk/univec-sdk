package core

import (
	"sync"
)

// MakeConfig builds a fresh, fully materialised config map. Every call
// rebuilds the whole structure, so prefer SharedConfig unless you need a
// private copy you intend to mutate.
func MakeConfig() map[string]any {
	return map[string]any{
		"main": map[string]any{
			"name": "Univec",
			"slug": "univec",
			"version": "0.1.1",
			"target": "go",
		},
		"feature": map[string]any{
			"test": map[string]any{
				"options": map[string]any{
					"active": false,
				},
			},
		},
		"options": map[string]any{
			"base": "https://api.univec.ai",
			"auth": map[string]any{
				"prefix": "Bearer",
			},
			"headers": map[string]any{
				"content-type": "application/json",
			},
			"entity": map[string]any{
				"convert": map[string]any{},
				"embed": map[string]any{},
				"ephemeral_key": map[string]any{},
				"model": map[string]any{},
			},
		},
		"entity": map[string]any{
			"convert": map[string]any{
				"fields": []any{
					map[string]any{
						"name": "bridge_model",
						"req": true,
						"short": "Embed model used to vectorise the text before translation.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "embeddings",
						"req": true,
						"short": "Translated vectors, in the target model's dimension.",
						"type": "`$ARRAY`",
					},
					map[string]any{
						"name": "source_model",
						"req": true,
						"short": "Model space the supplied vectors are currently in.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "target_model",
						"req": true,
						"short": "Model space to translate into.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "texts",
						"req": true,
						"short": "Texts to embed and translate.",
						"type": "`$ARRAY`",
					},
				},
				"name": "convert",
				"op": map[string]any{
					"create": map[string]any{
						"input": "data",
						"name": "create",
						"points": []any{
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/convert",
								"parts": []any{
									"v1",
									"convert",
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
							},
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/embed-bridge",
								"parts": []any{
									"v1",
									"embed-bridge",
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
							},
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/ephemeral/convert",
								"parts": []any{
									"v1",
									"ephemeral",
									"convert",
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
							},
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/ephemeral/embed-bridge",
								"parts": []any{
									"v1",
									"ephemeral",
									"embed-bridge",
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
							},
						},
					},
				},
				"relations": map[string]any{
					"ancestors": []any{},
				},
			},
			"embed": map[string]any{
				"fields": []any{
					map[string]any{
						"name": "embeddings",
						"req": true,
						"short": "One vector per input text, in input order.",
						"type": "`$ARRAY`",
					},
					map[string]any{
						"name": "model",
						"req": true,
						"short": "Model that produced the vectors.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "texts",
						"req": true,
						"short": "Texts to embed.",
						"type": "`$ARRAY`",
					},
				},
				"name": "embed",
				"op": map[string]any{
					"create": map[string]any{
						"input": "data",
						"name": "create",
						"points": []any{
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/embed",
								"parts": []any{
									"v1",
									"embed",
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
							},
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/ephemeral/embed",
								"parts": []any{
									"v1",
									"ephemeral",
									"embed",
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
							},
						},
					},
				},
				"relations": map[string]any{
					"ancestors": []any{},
				},
			},
			"ephemeral_key": map[string]any{
				"fields": []any{
					map[string]any{
						"name": "dailyLimit",
						"req": true,
						"short": "Calls permitted per day.",
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "dailyUsed",
						"req": true,
						"short": "Calls already used today.",
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "key",
						"req": true,
						"short": "The ephemeral API key, prefixed `eph_`.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "resetsAt",
						"req": true,
						"short": "When the daily allowance resets.",
						"type": "`$STRING`",
					},
				},
				"name": "ephemeral_key",
				"op": map[string]any{
					"create": map[string]any{
						"input": "data",
						"name": "create",
						"points": []any{
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/ephemeral/key",
								"parts": []any{
									"v1",
									"ephemeral",
									"key",
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
							},
						},
					},
				},
				"relations": map[string]any{
					"ancestors": []any{},
				},
			},
			"model": map[string]any{
				"fields": []any{
					map[string]any{
						"name": "eval",
						"short": "Retrieval-fidelity metrics for a convert model.",
						"type": "`$OBJECT`",
					},
					map[string]any{
						"name": "executionProvider",
						"short": "Hardware backend, e.g.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "modelCard",
						"short": "Convert models only: training provenance and architecture detail.",
						"type": "`$OBJECT`",
					},
					map[string]any{
						"name": "modelType",
						"req": true,
						"short": "`embed` for text-to-vector models, `convert` for space-translation models.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "name",
						"req": true,
						"short": "Model identifier used in requests.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "sequenceLen",
						"short": "Embed models only: maximum input sequence length.",
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "sourceDim",
						"short": "Convert models only: source vector dimension.",
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "sourceModel",
						"short": "Convert models only: the source model space.",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "targetDim",
						"req": true,
						"short": "Dimension of the produced vectors.",
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "targetModel",
						"req": true,
						"short": "The model space produced.",
						"type": "`$STRING`",
					},
				},
				"name": "model",
				"op": map[string]any{
					"list": map[string]any{
						"input": "data",
						"name": "list",
						"points": []any{
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "GET",
								"orig": "/v1/models",
								"parts": []any{
									"v1",
									"models",
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
							},
						},
					},
				},
				"relations": map[string]any{
					"ancestors": []any{},
				},
			},
		},
	}
}

var (
	sharedConfigOnce sync.Once
	sharedConfigVal  map[string]any
)

// SharedConfig returns the process-wide config, built once on first use.
// The SDK reads the config on every request and never writes to it, so one
// instance is shared by every client rather than rebuilt per client.
//
// The returned map is shared: treat it as read-only. Callers that need to
// mutate should use MakeConfig, which always returns a fresh copy.
func SharedConfig() map[string]any {
	sharedConfigOnce.Do(func() {
		sharedConfigVal = MakeConfig()
	})
	return sharedConfigVal
}

func makeFeature(name string) Feature {
	switch name {
	case "test":
		if NewTestFeatureFunc != nil {
			return NewTestFeatureFunc()
		}
	default:
		if NewBaseFeatureFunc != nil {
			return NewBaseFeatureFunc()
		}
	}
	return nil
}
