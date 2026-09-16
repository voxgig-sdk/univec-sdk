package core

import (
	"sync"

	"github.com/voxgig-sdk/univec-sdk/go/feature/secrets/plugins/boru"
	"github.com/voxgig-sdk/univec-sdk/go/feature/secrets/plugins/hashicorp"
)

// MakeConfig builds a fresh, fully materialised config map. Every call
// rebuilds the whole structure, so prefer SharedConfig unless you need a
// private copy you intend to mutate.
func MakeConfig() map[string]any {
	return map[string]any{
		"main": map[string]any{
			"name": "Univec",
			"slug": "univec",
			"version": "0.1.2",
			"target": "go",
		},
		"feature": map[string]any{
			"audit": map[string]any{
				"options": map[string]any{
					"active": false,
					"actor": "anonymous",
					"max": 1000,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"cache": map[string]any{
				"options": map[string]any{
					"active": false,
					"max": 256,
					"methods": []any{
						"GET",
					},
					"ttl": 5000,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "wrap",
			},
			"clienttrack": map[string]any{
				"options": map[string]any{
					"active": false,
					"clientVersion": "0.0.1",
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"cost": map[string]any{
				"options": map[string]any{
					"active": false,
					"budget": 0,
					"currency": "USD",
					"header": "",
					"onBudget": "warn",
					"path": "",
					"perUnit": 0,
					"rates": map[string]any{},
					"unit": 0,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "wrap",
			},
			"debug": map[string]any{
				"options": map[string]any{
					"active": false,
					"max": 100,
					"redact": []any{
						"authorization",
						"cookie",
						"set-cookie",
						"api-key",
						"apikey",
						"x-api-key",
						"idempotency-key",
					},
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"idempotency": map[string]any{
				"options": map[string]any{
					"active": false,
					"header": "Idempotency-Key",
					"methods": []any{
						"POST",
						"PUT",
						"PATCH",
						"DELETE",
					},
					"ops": []any{
						"create",
						"update",
						"remove",
					},
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"log": map[string]any{
				"options": map[string]any{
					"active": true,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"metrics": map[string]any{
				"options": map[string]any{
					"active": false,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"netsim": map[string]any{
				"options": map[string]any{
					"active": false,
					"errorTimes": 0,
					"failEvery": 0,
					"failRate": 0,
					"failStatus": 503,
					"failTimes": 0,
					"latency": 0,
					"offline": false,
					"rateLimitTimes": 0,
					"retryAfter": 0,
					"seed": 1,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "wrap",
			},
			"paging": map[string]any{
				"options": map[string]any{
					"active": false,
					"afterVar": "after",
					"cursorParam": "cursor",
					"firstVar": "first",
					"limitParam": "limit",
					"pageParam": "page",
					"startPage": 1,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"proxy": map[string]any{
				"options": map[string]any{
					"active": false,
					"fromEnv": false,
					"noProxy": []any{},
					"url": "",
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "wrap",
			},
			"ratelimit": map[string]any{
				"options": map[string]any{
					"active": false,
					"burst": 5,
					"rate": 5,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "wrap",
			},
			"rbac": map[string]any{
				"options": map[string]any{
					"active": false,
					"deny": false,
					"permissions": []any{},
					"rules": map[string]any{},
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"retry": map[string]any{
				"options": map[string]any{
					"active": false,
					"factor": 2,
					"maxDelay": 2000,
					"minDelay": 50,
					"retries": 2,
					"statuses": []any{
						408,
						425,
						429,
						500,
						502,
						503,
						504,
					},
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "wrap",
			},
			"secrets": map[string]any{
				"options": map[string]any{
					"active": false,
					"cache": true,
					"exchange": map[string]any{
						"active": false,
						"method": "POST",
						"path": "auth/token",
						"refresh": "",
						"request": "refresh_token",
						"response": "access_token",
						"retries": 1,
						"statuses": []any{
							401,
						},
					},
					"name": "univec",
					"providers": []any{
						map[string]any{
							"kind": "boru",
							"namespace": "sdk",
						},
					},
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "wrap",
			},
			"streaming": map[string]any{
				"options": map[string]any{
					"active": false,
					"chunkDelay": 0,
					"chunkSize": 0,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"telemetry": map[string]any{
				"options": map[string]any{
					"active": false,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "none",
			},
			"test": map[string]any{
				"options": map[string]any{
					"active": false,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "base",
			},
			"timeout": map[string]any{
				"options": map[string]any{
					"active": false,
					"ms": 30000,
				},
				"optspec": map[string]any{},
				"strict": false,
				"transport": "wrap",
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
								"segments": []any{
									map[string]any{
										"lit": "v1",
									},
									map[string]any{
										"lit": "convert",
									},
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
								"parts": []any{
									"v1",
									"convert",
								},
							},
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/embed-bridge",
								"segments": []any{
									map[string]any{
										"lit": "v1",
									},
									map[string]any{
										"lit": "embed-bridge",
									},
								},
								"select": map[string]any{
									"$action": "bridge",
								},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
								"parts": []any{
									"v1",
									"embed-bridge",
								},
							},
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/ephemeral/convert",
								"segments": []any{
									map[string]any{
										"lit": "v1",
									},
									map[string]any{
										"lit": "ephemeral",
									},
									map[string]any{
										"lit": "convert",
									},
								},
								"select": map[string]any{
									"$action": "ephemeral",
								},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
								"parts": []any{
									"v1",
									"ephemeral",
									"convert",
								},
							},
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/ephemeral/embed-bridge",
								"segments": []any{
									map[string]any{
										"lit": "v1",
									},
									map[string]any{
										"lit": "ephemeral",
									},
									map[string]any{
										"lit": "embed-bridge",
									},
								},
								"select": map[string]any{
									"$action": "ephemeral_bridge",
								},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
								"parts": []any{
									"v1",
									"ephemeral",
									"embed-bridge",
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
								"segments": []any{
									map[string]any{
										"lit": "v1",
									},
									map[string]any{
										"lit": "embed",
									},
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
								"parts": []any{
									"v1",
									"embed",
								},
							},
							map[string]any{
								"args": map[string]any{},
								"kind": "http",
								"method": "POST",
								"orig": "/v1/ephemeral/embed",
								"segments": []any{
									map[string]any{
										"lit": "v1",
									},
									map[string]any{
										"lit": "ephemeral",
									},
									map[string]any{
										"lit": "embed",
									},
								},
								"select": map[string]any{
									"$action": "ephemeral",
								},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
								"parts": []any{
									"v1",
									"ephemeral",
									"embed",
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
						"format": "date-time",
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
								"segments": []any{
									map[string]any{
										"lit": "v1",
									},
									map[string]any{
										"lit": "ephemeral",
									},
									map[string]any{
										"lit": "key",
									},
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
								"parts": []any{
									"v1",
									"ephemeral",
									"key",
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
								"segments": []any{
									map[string]any{
										"lit": "v1",
									},
									map[string]any{
										"lit": "models",
									},
								},
								"select": map[string]any{},
								"transform": map[string]any{
									"req": "`reqdata`",
									"res": "`body.data`",
								},
								"parts": []any{
									"v1",
									"models",
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

// The plugin definitions the model selected per feature, as []any so a
// feature package can consume them without core naming its types. Empty
// when no active feature declares active plugin groups for this target.
var featurePlugins = map[string][]any{
	"secrets": {boru.Plugin, hashicorp.Plugin},
}

// FeaturePlugins is the definitions list for one feature's chain.
func FeaturePlugins(name string) []any {
	return featurePlugins[name]
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
	case "audit":
		if NewAuditFeatureFunc != nil {
			return NewAuditFeatureFunc()
		}
	case "cache":
		if NewCacheFeatureFunc != nil {
			return NewCacheFeatureFunc()
		}
	case "clienttrack":
		if NewClienttrackFeatureFunc != nil {
			return NewClienttrackFeatureFunc()
		}
	case "cost":
		if NewCostFeatureFunc != nil {
			return NewCostFeatureFunc()
		}
	case "debug":
		if NewDebugFeatureFunc != nil {
			return NewDebugFeatureFunc()
		}
	case "idempotency":
		if NewIdempotencyFeatureFunc != nil {
			return NewIdempotencyFeatureFunc()
		}
	case "log":
		if NewLogFeatureFunc != nil {
			return NewLogFeatureFunc()
		}
	case "metrics":
		if NewMetricsFeatureFunc != nil {
			return NewMetricsFeatureFunc()
		}
	case "netsim":
		if NewNetsimFeatureFunc != nil {
			return NewNetsimFeatureFunc()
		}
	case "paging":
		if NewPagingFeatureFunc != nil {
			return NewPagingFeatureFunc()
		}
	case "proxy":
		if NewProxyFeatureFunc != nil {
			return NewProxyFeatureFunc()
		}
	case "ratelimit":
		if NewRatelimitFeatureFunc != nil {
			return NewRatelimitFeatureFunc()
		}
	case "rbac":
		if NewRbacFeatureFunc != nil {
			return NewRbacFeatureFunc()
		}
	case "retry":
		if NewRetryFeatureFunc != nil {
			return NewRetryFeatureFunc()
		}
	case "secrets":
		if NewSecretsFeatureFunc != nil {
			return NewSecretsFeatureFunc()
		}
	case "streaming":
		if NewStreamingFeatureFunc != nil {
			return NewStreamingFeatureFunc()
		}
	case "telemetry":
		if NewTelemetryFeatureFunc != nil {
			return NewTelemetryFeatureFunc()
		}
	case "test":
		if NewTestFeatureFunc != nil {
			return NewTestFeatureFunc()
		}
	case "timeout":
		if NewTimeoutFeatureFunc != nil {
			return NewTimeoutFeatureFunc()
		}
	default:
		if NewBaseFeatureFunc != nil {
			return NewBaseFeatureFunc()
		}
	}
	return nil
}
