# Univec SDK configuration
#
# Returns the resolved SDK config as vendored-struct nodes (via
# Univec.Helpers.deep/1). Do not edit by hand.

defmodule Univec.Config do
  def make_config do
    Univec.Helpers.deep(%{
      "main" => %{
        "name" => "Univec",
        "slug" => "univec",
        "version" => "0.1.2",
        "target" => "elixir"
      },
      "feature" => %{
        "audit" => %{
          "options" => %{
            "active" => false,
            "actor" => "anonymous",
            "max" => 1000
          },
          "optspec" => %{
            "now" => "`$FUNCTION`",
            "sink" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "cache" => %{
          "options" => %{
            "active" => false,
            "max" => 256,
            "methods" => [
              "GET"
            ],
            "ttl" => 5000
          },
          "optspec" => %{
            "now" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "wrap"
        },
        "clienttrack" => %{
          "options" => %{
            "active" => false,
            "clientVersion" => "0.0.1"
          },
          "optspec" => %{
            "clientName" => "`$STRING`",
            "clientVersion" => "`$STRING`",
            "headers" => "`$MAP`",
            "idgen" => "`$FUNCTION`",
            "sessionId" => "`$STRING`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "cost" => %{
          "options" => %{
            "active" => false,
            "budget" => 0,
            "currency" => "USD",
            "header" => "",
            "onBudget" => "warn",
            "path" => "",
            "perUnit" => 0,
            "rates" => %{},
            "unit" => 0
          },
          "optspec" => %{
            "actor" => "`$STRING`",
            "sink" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "wrap"
        },
        "debug" => %{
          "options" => %{
            "active" => false,
            "max" => 100,
            "redact" => [
              "authorization",
              "cookie",
              "set-cookie",
              "api-key",
              "apikey",
              "x-api-key",
              "idempotency-key"
            ]
          },
          "optspec" => %{
            "now" => "`$FUNCTION`",
            "onEntry" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "idempotency" => %{
          "options" => %{
            "active" => false,
            "header" => "Idempotency-Key",
            "methods" => [
              "POST",
              "PUT",
              "PATCH",
              "DELETE"
            ],
            "ops" => [
              "create",
              "update",
              "remove"
            ]
          },
          "optspec" => %{
            "keygen" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "log" => %{
          "options" => %{
            "active" => true
          },
          "optspec" => %{
            "level" => "`$STRING`",
            "logger" => "`$ANY`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "metrics" => %{
          "options" => %{
            "active" => false
          },
          "optspec" => %{
            "now" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "netsim" => %{
          "options" => %{
            "active" => false,
            "errorTimes" => 0,
            "failEvery" => 0,
            "failRate" => 0,
            "failStatus" => 503,
            "failTimes" => 0,
            "latency" => 0,
            "offline" => false,
            "rateLimitTimes" => 0,
            "retryAfter" => 0,
            "seed" => 1
          },
          "optspec" => %{
            "latency" => [
              "`$ONE`",
              "`$NUMBER`",
              "`$MAP`"
            ],
            "sleep" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "wrap"
        },
        "paging" => %{
          "options" => %{
            "active" => false,
            "afterVar" => "after",
            "cursorParam" => "cursor",
            "firstVar" => "first",
            "limitParam" => "limit",
            "pageParam" => "page",
            "startPage" => 1
          },
          "optspec" => %{
            "limit" => "`$NUMBER`",
            "ops" => "`$LIST`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "proxy" => %{
          "options" => %{
            "active" => false,
            "fromEnv" => false,
            "noProxy" => [],
            "url" => ""
          },
          "optspec" => %{
            "agent" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "wrap"
        },
        "ratelimit" => %{
          "options" => %{
            "active" => false,
            "burst" => 5,
            "rate" => 5
          },
          "optspec" => %{
            "now" => "`$FUNCTION`",
            "sleep" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "wrap"
        },
        "rbac" => %{
          "options" => %{
            "active" => false,
            "deny" => false,
            "permissions" => [],
            "rules" => %{}
          },
          "optspec" => %{},
          "strict" => false,
          "transport" => "none"
        },
        "retry" => %{
          "options" => %{
            "active" => false,
            "factor" => 2,
            "maxDelay" => 2000,
            "minDelay" => 50,
            "retries" => 2,
            "statuses" => [
              408,
              425,
              429,
              500,
              502,
              503,
              504
            ]
          },
          "optspec" => %{
            "jitter" => "`$BOOLEAN`",
            "sleep" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "wrap"
        },
        "secrets" => %{
          "options" => %{
            "active" => false,
            "cache" => true,
            "exchange" => %{
              "active" => false,
              "method" => "POST",
              "path" => "auth/token",
              "refresh" => "",
              "request" => "refresh_token",
              "response" => "access_token",
              "retries" => 1,
              "statuses" => [
                401
              ]
            },
            "name" => "univec",
            "providers" => [
              %{
                "kind" => "boru",
                "namespace" => "sdk"
              }
            ]
          },
          "optspec" => %{},
          "strict" => false,
          "transport" => "wrap"
        },
        "streaming" => %{
          "options" => %{
            "active" => false,
            "chunkDelay" => 0,
            "chunkSize" => 0
          },
          "optspec" => %{
            "ops" => "`$LIST`",
            "sleep" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "telemetry" => %{
          "options" => %{
            "active" => false
          },
          "optspec" => %{
            "exporter" => "`$FUNCTION`",
            "headers" => "`$MAP`",
            "idgen" => "`$FUNCTION`",
            "now" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "none"
        },
        "test" => %{
          "options" => %{
            "active" => false
          },
          "optspec" => %{
            "entity" => "`$MAP`",
            "net" => "`$MAP`"
          },
          "strict" => false,
          "transport" => "base"
        },
        "timeout" => %{
          "options" => %{
            "active" => false,
            "ms" => 30000
          },
          "optspec" => %{
            "clearTimer" => "`$FUNCTION`",
            "setTimer" => "`$FUNCTION`"
          },
          "strict" => false,
          "transport" => "wrap"
        },
      },
      "options" => %{
        "base" => "https://api.univec.ai",
        "auth" => %{
          "prefix" => "Bearer"
        },
        "headers" => %{
          "content-type" => "application/json"
        },
        "entity" => %{
          "convert" => %{},
          "embed" => %{},
          "ephemeral_key" => %{},
          "model" => %{}
        }
      },
      "entity" => %{
        "convert" => %{
          "fields" => [
            %{
              "name" => "embeddings",
              "req" => true,
              "short" => "Translated vectors, in the target model's dimension.",
              "type" => "`$ARRAY`"
            },
            %{
              "name" => "source_model",
              "req" => true,
              "short" => "Model space the supplied vectors are currently in.",
              "type" => "`$STRING`"
            },
            %{
              "name" => "target_model",
              "req" => true,
              "short" => "Model space to translate into.",
              "type" => "`$STRING`"
            }
          ],
          "name" => "convert",
          "op" => %{
            "create" => %{
              "input" => "data",
              "name" => "create",
              "points" => [
                %{
                  "args" => %{},
                  "kind" => "http",
                  "live" => %{
                    "assert" => %{
                      "equal" => %{
                        "source_model" => %{
                          "from" => "models",
                          "path" => "sourceModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "target_model" => %{
                          "from" => "models",
                          "path" => "targetModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        }
                      },
                      "vectors" => %{
                        "count" => 1,
                        "dimension" => %{
                          "from" => "models",
                          "path" => "targetDim",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "path" => "embeddings"
                      }
                    },
                    "auth" => "account",
                    "id" => "account-convert",
                    "input" => %{
                      "embeddings" => %{
                        "from" => "account-embed",
                        "path" => "embeddings"
                      },
                      "source_model" => %{
                        "from" => "models",
                        "path" => "sourceModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      },
                      "target_model" => %{
                        "from" => "models",
                        "path" => "targetModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      }
                    }
                  },
                  "method" => "POST",
                  "orig" => "/v1/convert",
                  "segments" => [
                    %{
                      "lit" => "v1"
                    },
                    %{
                      "lit" => "convert"
                    }
                  ],
                  "select" => %{},
                  "transform" => %{
                    "req" => "`reqdata`",
                    "res" => "`body.data`"
                  },
                  "parts" => [
                    "v1",
                    "convert"
                  ]
                },
                %{
                  "args" => %{},
                  "kind" => "http",
                  "live" => %{
                    "assert" => %{
                      "equal" => %{
                        "bridge_model" => %{
                          "from" => "models",
                          "path" => "sourceModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "target_model" => %{
                          "from" => "models",
                          "path" => "targetModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        }
                      },
                      "vectors" => %{
                        "count" => 1,
                        "dimension" => %{
                          "from" => "models",
                          "path" => "targetDim",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "path" => "embeddings"
                      }
                    },
                    "auth" => "account",
                    "id" => "account-embed-bridge",
                    "input" => %{
                      "bridge_model" => %{
                        "from" => "models",
                        "path" => "sourceModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      },
                      "target_model" => %{
                        "from" => "models",
                        "path" => "targetModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      },
                      "texts" => [
                        "SDK live coverage test."
                      ]
                    }
                  },
                  "method" => "POST",
                  "orig" => "/v1/embed-bridge",
                  "segments" => [
                    %{
                      "lit" => "v1"
                    },
                    %{
                      "lit" => "embed-bridge"
                    }
                  ],
                  "select" => %{
                    "$action" => "bridge"
                  },
                  "transform" => %{
                    "req" => "`reqdata`",
                    "res" => "`body.data`"
                  },
                  "parts" => [
                    "v1",
                    "embed-bridge"
                  ]
                },
                %{
                  "args" => %{},
                  "kind" => "http",
                  "live" => %{
                    "assert" => %{
                      "equal" => %{
                        "source_model" => %{
                          "from" => "models",
                          "path" => "sourceModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "target_model" => %{
                          "from" => "models",
                          "path" => "targetModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        }
                      },
                      "vectors" => %{
                        "count" => 1,
                        "dimension" => %{
                          "from" => "models",
                          "path" => "targetDim",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "path" => "embeddings"
                      }
                    },
                    "auth" => "issued",
                    "credential" => %{
                      "from" => "key",
                      "path" => "key"
                    },
                    "id" => "ephemeral-convert",
                    "input" => %{
                      "embeddings" => %{
                        "from" => "ephemeral-embed",
                        "path" => "embeddings"
                      },
                      "source_model" => %{
                        "from" => "models",
                        "path" => "sourceModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      },
                      "target_model" => %{
                        "from" => "models",
                        "path" => "targetModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      }
                    }
                  },
                  "method" => "POST",
                  "orig" => "/v1/ephemeral/convert",
                  "segments" => [
                    %{
                      "lit" => "v1"
                    },
                    %{
                      "lit" => "ephemeral"
                    },
                    %{
                      "lit" => "convert"
                    }
                  ],
                  "select" => %{
                    "$action" => "ephemeral"
                  },
                  "transform" => %{
                    "req" => "`reqdata`",
                    "res" => "`body.data`"
                  },
                  "parts" => [
                    "v1",
                    "ephemeral",
                    "convert"
                  ]
                },
                %{
                  "args" => %{},
                  "kind" => "http",
                  "live" => %{
                    "assert" => %{
                      "equal" => %{
                        "bridge_model" => %{
                          "from" => "models",
                          "path" => "sourceModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "target_model" => %{
                          "from" => "models",
                          "path" => "targetModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        }
                      },
                      "vectors" => %{
                        "count" => 1,
                        "dimension" => %{
                          "from" => "models",
                          "path" => "targetDim",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "path" => "embeddings"
                      }
                    },
                    "auth" => "issued",
                    "credential" => %{
                      "from" => "key",
                      "path" => "key"
                    },
                    "id" => "ephemeral-embed-bridge",
                    "input" => %{
                      "bridge_model" => %{
                        "from" => "models",
                        "path" => "sourceModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      },
                      "target_model" => %{
                        "from" => "models",
                        "path" => "targetModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      },
                      "texts" => [
                        "SDK live coverage test."
                      ]
                    }
                  },
                  "method" => "POST",
                  "orig" => "/v1/ephemeral/embed-bridge",
                  "segments" => [
                    %{
                      "lit" => "v1"
                    },
                    %{
                      "lit" => "ephemeral"
                    },
                    %{
                      "lit" => "embed-bridge"
                    }
                  ],
                  "select" => %{
                    "$action" => "ephemeral_bridge"
                  },
                  "transform" => %{
                    "req" => "`reqdata`",
                    "res" => "`body.data`"
                  },
                  "parts" => [
                    "v1",
                    "ephemeral",
                    "embed-bridge"
                  ]
                }
              ]
            }
          },
          "relations" => %{
            "ancestors" => []
          }
        },
        "embed" => %{
          "fields" => [
            %{
              "name" => "embeddings",
              "req" => true,
              "short" => "One vector per input text, in input order.",
              "type" => "`$ARRAY`"
            },
            %{
              "name" => "model",
              "req" => true,
              "short" => "Model that produced the vectors.",
              "type" => "`$STRING`"
            },
            %{
              "name" => "texts",
              "req" => true,
              "short" => "Texts to embed.",
              "type" => "`$ARRAY`"
            }
          ],
          "name" => "embed",
          "op" => %{
            "create" => %{
              "input" => "data",
              "name" => "create",
              "points" => [
                %{
                  "args" => %{},
                  "kind" => "http",
                  "live" => %{
                    "assert" => %{
                      "equal" => %{
                        "model" => %{
                          "from" => "models",
                          "path" => "sourceModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        }
                      },
                      "vectors" => %{
                        "count" => 1,
                        "dimension" => %{
                          "from" => "models",
                          "path" => "sourceDim",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "path" => "embeddings"
                      }
                    },
                    "auth" => "account",
                    "id" => "account-embed",
                    "input" => %{
                      "model" => %{
                        "from" => "models",
                        "path" => "sourceModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      },
                      "texts" => [
                        "SDK live coverage test."
                      ]
                    }
                  },
                  "method" => "POST",
                  "orig" => "/v1/embed",
                  "segments" => [
                    %{
                      "lit" => "v1"
                    },
                    %{
                      "lit" => "embed"
                    }
                  ],
                  "select" => %{},
                  "transform" => %{
                    "req" => "`reqdata`",
                    "res" => "`body.data`"
                  },
                  "parts" => [
                    "v1",
                    "embed"
                  ]
                },
                %{
                  "args" => %{},
                  "kind" => "http",
                  "live" => %{
                    "assert" => %{
                      "equal" => %{
                        "model" => %{
                          "from" => "models",
                          "path" => "sourceModel",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        }
                      },
                      "vectors" => %{
                        "count" => 1,
                        "dimension" => %{
                          "from" => "models",
                          "path" => "sourceDim",
                          "related" => %{
                            "foreign" => "name",
                            "from" => "models",
                            "local" => "sourceModel",
                            "where" => %{
                              "modelType" => "embed"
                            }
                          },
                          "where" => %{
                            "modelType" => "convert"
                          }
                        },
                        "path" => "embeddings"
                      }
                    },
                    "auth" => "issued",
                    "credential" => %{
                      "from" => "key",
                      "path" => "key"
                    },
                    "id" => "ephemeral-embed",
                    "input" => %{
                      "model" => %{
                        "from" => "models",
                        "path" => "sourceModel",
                        "related" => %{
                          "foreign" => "name",
                          "from" => "models",
                          "local" => "sourceModel",
                          "where" => %{
                            "modelType" => "embed"
                          }
                        },
                        "where" => %{
                          "modelType" => "convert"
                        }
                      },
                      "texts" => [
                        "SDK live coverage test."
                      ]
                    }
                  },
                  "method" => "POST",
                  "orig" => "/v1/ephemeral/embed",
                  "segments" => [
                    %{
                      "lit" => "v1"
                    },
                    %{
                      "lit" => "ephemeral"
                    },
                    %{
                      "lit" => "embed"
                    }
                  ],
                  "select" => %{
                    "$action" => "ephemeral"
                  },
                  "transform" => %{
                    "req" => "`reqdata`",
                    "res" => "`body.data`"
                  },
                  "parts" => [
                    "v1",
                    "ephemeral",
                    "embed"
                  ]
                }
              ]
            }
          },
          "relations" => %{
            "ancestors" => []
          }
        },
        "ephemeral_key" => %{
          "fields" => [
            %{
              "name" => "dailyLimit",
              "req" => true,
              "short" => "Calls permitted per day.",
              "type" => "`$INTEGER`"
            },
            %{
              "name" => "dailyUsed",
              "req" => true,
              "short" => "Calls already used today.",
              "type" => "`$INTEGER`"
            },
            %{
              "name" => "key",
              "req" => true,
              "short" => "The ephemeral API key, prefixed `eph_`.",
              "type" => "`$STRING`"
            },
            %{
              "format" => "date-time",
              "name" => "resetsAt",
              "req" => true,
              "short" => "When the daily allowance resets.",
              "type" => "`$STRING`"
            }
          ],
          "name" => "ephemeral_key",
          "op" => %{
            "create" => %{
              "input" => "data",
              "name" => "create",
              "points" => [
                %{
                  "args" => %{},
                  "kind" => "http",
                  "live" => %{
                    "assert" => %{
                      "nonempty" => [
                        "key"
                      ]
                    },
                    "auth" => "public",
                    "id" => "key",
                    "retention" => "No deletion endpoint; issued key is subject to the service daily allowance"
                  },
                  "method" => "POST",
                  "orig" => "/v1/ephemeral/key",
                  "segments" => [
                    %{
                      "lit" => "v1"
                    },
                    %{
                      "lit" => "ephemeral"
                    },
                    %{
                      "lit" => "key"
                    }
                  ],
                  "select" => %{},
                  "transform" => %{
                    "req" => "`reqdata`",
                    "res" => "`body.data`"
                  },
                  "parts" => [
                    "v1",
                    "ephemeral",
                    "key"
                  ]
                }
              ]
            }
          },
          "relations" => %{
            "ancestors" => []
          }
        },
        "model" => %{
          "fields" => [
            %{
              "name" => "eval",
              "short" => "Retrieval-fidelity metrics for a convert model.",
              "type" => "`$OBJECT`"
            },
            %{
              "name" => "executionProvider",
              "short" => "Hardware backend, e.g.",
              "type" => "`$STRING`"
            },
            %{
              "name" => "modelCard",
              "short" => "Convert models only: training provenance and architecture detail.",
              "type" => "`$OBJECT`"
            },
            %{
              "name" => "modelType",
              "req" => true,
              "short" => "`embed` for text-to-vector models, `convert` for space-translation models.",
              "type" => "`$STRING`"
            },
            %{
              "name" => "name",
              "req" => true,
              "short" => "Model identifier used in requests.",
              "type" => "`$STRING`"
            },
            %{
              "name" => "sequenceLen",
              "short" => "Embed models only: maximum input sequence length.",
              "type" => "`$INTEGER`"
            },
            %{
              "name" => "sourceDim",
              "short" => "Convert models only: source vector dimension.",
              "type" => "`$INTEGER`"
            },
            %{
              "name" => "sourceModel",
              "short" => "Convert models only: the source model space.",
              "type" => "`$STRING`"
            },
            %{
              "name" => "targetDim",
              "req" => true,
              "short" => "Dimension of the produced vectors.",
              "type" => "`$INTEGER`"
            },
            %{
              "name" => "targetModel",
              "req" => true,
              "short" => "The model space produced.",
              "type" => "`$STRING`"
            }
          ],
          "name" => "model",
          "op" => %{
            "list" => %{
              "input" => "data",
              "name" => "list",
              "points" => [
                %{
                  "args" => %{},
                  "kind" => "http",
                  "live" => %{
                    "assert" => %{
                      "nonempty" => [
                        ""
                      ]
                    },
                    "auth" => "public",
                    "id" => "models"
                  },
                  "method" => "GET",
                  "orig" => "/v1/models",
                  "segments" => [
                    %{
                      "lit" => "v1"
                    },
                    %{
                      "lit" => "models"
                    }
                  ],
                  "select" => %{},
                  "transform" => %{
                    "req" => "`reqdata`",
                    "res" => "`body.data`"
                  },
                  "parts" => [
                    "v1",
                    "models"
                  ]
                }
              ]
            }
          },
          "relations" => %{
            "ancestors" => []
          }
        }
      }
    })
  end

  # SHARED CONFIG (sdkgen rung L2). See the data branch for the rationale, and
  # for why the cached handle is validated on read.
  @shared_key {__MODULE__, :shared_config}

  # The process-wide config, built once on first use. The returned node is
  # SHARED: treat it as read-only. Callers that need to mutate should use
  # make_config, which always returns a fresh copy.
  def shared_config do
    cached = :persistent_term.get(@shared_key, nil)

    if cached != nil and usable?(cached) do
      cached
    else
      cfg = make_config()
      :persistent_term.put(@shared_key, cfg)
      cfg
    end
  end

  defp usable?(cfg) do
    Voxgig.Struct.getprop(cfg, "main")
    true
  rescue
    ArgumentError -> false
  end

  # The plugin definitions the model selected per feature. Empty when no
  # active feature declares active plugin groups for this target.
  def feature_plugins(name) do
    case name do
      "secrets" -> [Sekreto.Plugins.Boru.boru(), Sekreto.Plugins.Hashicorp.hashicorp()]
      _ -> []
    end
  end
end
