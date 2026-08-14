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
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "embeddings",
						"req": true,
						"type": "`$ARRAY`",
					},
					map[string]any{
						"name": "source_model",
						"req": true,
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "target_model",
						"req": true,
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "texts",
						"req": true,
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
						"type": "`$ARRAY`",
					},
					map[string]any{
						"name": "model",
						"req": true,
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "texts",
						"req": true,
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
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "dailyUsed",
						"req": true,
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "key",
						"req": true,
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "resetsAt",
						"req": true,
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
						"type": "`$OBJECT`",
					},
					map[string]any{
						"name": "executionProvider",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "modelCard",
						"type": "`$OBJECT`",
					},
					map[string]any{
						"name": "modelType",
						"req": true,
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "name",
						"req": true,
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "sequenceLen",
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "sourceDim",
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "sourceModel",
						"type": "`$STRING`",
					},
					map[string]any{
						"name": "targetDim",
						"req": true,
						"type": "`$INTEGER`",
					},
					map[string]any{
						"name": "targetModel",
						"req": true,
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
