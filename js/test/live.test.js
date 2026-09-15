const { test } = require('node:test')
const { SDK } = require('..')
const { runLiveScenarios } = require('./live-scenarios')
const { loadEnvLocal } = require('./utility')
loadEnvLocal(__dirname + '/../.env.local')
test('live operation coverage', { skip: process.env.UNIVEC_TEST_LIVE !== 'TRUE' }, async () => {
  await runLiveScenarios(SDK, [
  {
    "entity": "convert",
    "accessor": "Convert",
    "op": "create",
    "id": "POST /v1/convert",
    "contractVersion": 1,
    "kind": "http",
    "path": "/v1/convert",
    "method": "POST",
    "args": {},
    "facts": {
      "live": {
        "assert": {
          "equal": {
            "source_model": {
              "from": "models",
              "path": "sourceModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "target_model": {
              "from": "models",
              "path": "targetModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            }
          },
          "vectors": {
            "count": 1,
            "dimension": {
              "from": "models",
              "path": "targetDim",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "path": "embeddings"
          }
        },
        "auth": "account",
        "id": "account-convert",
        "input": {
          "embeddings": {
            "from": "account-embed",
            "path": "embeddings"
          },
          "source_model": {
            "from": "models",
            "path": "sourceModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          },
          "target_model": {
            "from": "models",
            "path": "targetModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          }
        }
      },
      "operationId": "convertEmbedding",
      "parameters": [],
      "protocol": "http",
      "requestBody": {
        "content": {
          "application/json": {
            "example": {
              "embeddings": [
                [
                  0.01,
                  0.02,
                  0.03
                ]
              ],
              "source_model": "alibaba-nlp-gte-large-en-v1.5",
              "target_model": "nomic-embed-text-v1.5"
            },
            "schema": {
              "properties": {
                "embeddings": {
                  "description": "Vectors to translate. Each must match the source model's dimension exactly.",
                  "items": {
                    "description": "A single embedding vector.",
                    "items": {
                      "format": "float",
                      "type": "number"
                    },
                    "type": "array"
                  },
                  "type": "array"
                },
                "source_model": {
                  "description": "Model space the supplied vectors are currently in.",
                  "example": "alibaba-nlp-gte-large-en-v1.5",
                  "type": "string"
                },
                "target_model": {
                  "description": "Model space to translate into. A converter must exist for the source/target pair — see listModels.",
                  "example": "nomic-embed-text-v1.5",
                  "type": "string"
                }
              },
              "required": [
                "source_model",
                "target_model",
                "embeddings"
              ],
              "type": "object"
            }
          }
        },
        "required": true
      },
      "responses": {
        "200": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "data": {
                    "properties": {
                      "embeddings": {
                        "description": "Translated vectors, in the target model's dimension.",
                        "items": {
                          "description": "A single embedding vector.",
                          "items": {
                            "format": "float",
                            "type": "number"
                          },
                          "type": "array"
                        },
                        "type": "array"
                      },
                      "source_model": {
                        "type": "string"
                      },
                      "target_model": {
                        "type": "string"
                      }
                    },
                    "required": [
                      "embeddings",
                      "source_model",
                      "target_model"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "data"
                ],
                "type": "object"
              }
            }
          },
          "description": "Translated embeddings"
        },
        "401": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "422": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        }
      },
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySchemes": {
        "bearerAuth": {
          "description": "UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.",
          "scheme": "bearer",
          "type": "http"
        }
      },
      "securitySource": "definition"
    },
    "reachable": true
  },
  {
    "entity": "convert",
    "accessor": "Convert",
    "op": "create",
    "id": "POST /v1/embed-bridge",
    "contractVersion": 1,
    "kind": "http",
    "path": "/v1/embed-bridge",
    "method": "POST",
    "action": "bridge",
    "args": {},
    "facts": {
      "factSources": {
        "responses": "guide"
      },
      "live": {
        "assert": {
          "equal": {
            "bridge_model": {
              "from": "models",
              "path": "sourceModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "target_model": {
              "from": "models",
              "path": "targetModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            }
          },
          "vectors": {
            "count": 1,
            "dimension": {
              "from": "models",
              "path": "targetDim",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "path": "embeddings"
          }
        },
        "auth": "account",
        "id": "account-embed-bridge",
        "input": {
          "bridge_model": {
            "from": "models",
            "path": "sourceModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          },
          "target_model": {
            "from": "models",
            "path": "targetModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          },
          "texts": [
            "SDK live coverage test."
          ]
        }
      },
      "operationId": "embedBridge",
      "parameters": [],
      "protocol": "http",
      "requestBody": {
        "content": {
          "application/json": {
            "example": {
              "bridge_model": "alibaba-nlp-gte-large-en-v1.5",
              "target_model": "nomic-embed-text-v1.5",
              "texts": [
                "hello world"
              ]
            },
            "schema": {
              "properties": {
                "bridge_model": {
                  "description": "Embed model used to vectorise the text before translation.",
                  "example": "alibaba-nlp-gte-large-en-v1.5",
                  "type": "string"
                },
                "target_model": {
                  "description": "Model space to translate into.",
                  "example": "nomic-embed-text-v1.5",
                  "type": "string"
                },
                "texts": {
                  "description": "Texts to embed and translate.",
                  "example": [
                    "hello world"
                  ],
                  "items": {
                    "type": "string"
                  },
                  "type": "array"
                }
              },
              "required": [
                "bridge_model",
                "target_model",
                "texts"
              ],
              "type": "object"
            }
          }
        },
        "required": true
      },
      "responses": {
        "200": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "data": {
                    "properties": {
                      "bridge_model": {
                        "type": "string"
                      },
                      "embeddings": {
                        "description": "Translated vectors, in the target model's dimension.",
                        "items": {
                          "description": "A single embedding vector.",
                          "items": {
                            "format": "float",
                            "type": "number"
                          },
                          "type": "array"
                        },
                        "type": "array"
                      },
                      "model": {
                        "type": "string"
                      },
                      "target_model": {
                        "type": "string"
                      }
                    },
                    "required": [
                      "embeddings",
                      "bridge_model",
                      "target_model"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "data"
                ],
                "type": "object"
              }
            }
          },
          "description": "Translated embeddings"
        },
        "401": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "422": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        }
      },
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySchemes": {
        "bearerAuth": {
          "description": "UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.",
          "scheme": "bearer",
          "type": "http"
        }
      },
      "securitySource": "definition"
    },
    "reachable": true
  },
  {
    "entity": "convert",
    "accessor": "Convert",
    "op": "create",
    "id": "POST /v1/ephemeral/convert",
    "contractVersion": 1,
    "kind": "http",
    "path": "/v1/ephemeral/convert",
    "method": "POST",
    "action": "ephemeral",
    "args": {},
    "facts": {
      "live": {
        "assert": {
          "equal": {
            "source_model": {
              "from": "models",
              "path": "sourceModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "target_model": {
              "from": "models",
              "path": "targetModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            }
          },
          "vectors": {
            "count": 1,
            "dimension": {
              "from": "models",
              "path": "targetDim",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "path": "embeddings"
          }
        },
        "auth": "issued",
        "credential": {
          "from": "key",
          "path": "key"
        },
        "id": "ephemeral-convert",
        "input": {
          "embeddings": {
            "from": "ephemeral-embed",
            "path": "embeddings"
          },
          "source_model": {
            "from": "models",
            "path": "sourceModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          },
          "target_model": {
            "from": "models",
            "path": "targetModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          }
        }
      },
      "operationId": "convertEphemeralEmbedding",
      "parameters": [],
      "protocol": "http",
      "requestBody": {
        "content": {
          "application/json": {
            "example": {
              "embeddings": [
                [
                  0.01,
                  0.02,
                  0.03
                ]
              ],
              "source_model": "alibaba-nlp-gte-large-en-v1.5",
              "target_model": "nomic-embed-text-v1.5"
            },
            "schema": {
              "properties": {
                "embeddings": {
                  "description": "Vectors to translate. Each must match the source model's dimension exactly.",
                  "items": {
                    "description": "A single embedding vector.",
                    "items": {
                      "format": "float",
                      "type": "number"
                    },
                    "type": "array"
                  },
                  "type": "array"
                },
                "source_model": {
                  "description": "Model space the supplied vectors are currently in.",
                  "example": "alibaba-nlp-gte-large-en-v1.5",
                  "type": "string"
                },
                "target_model": {
                  "description": "Model space to translate into. A converter must exist for the source/target pair — see listModels.",
                  "example": "nomic-embed-text-v1.5",
                  "type": "string"
                }
              },
              "required": [
                "source_model",
                "target_model",
                "embeddings"
              ],
              "type": "object"
            }
          }
        },
        "required": true
      },
      "responses": {
        "200": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "data": {
                    "properties": {
                      "embeddings": {
                        "description": "Translated vectors, in the target model's dimension.",
                        "items": {
                          "description": "A single embedding vector.",
                          "items": {
                            "format": "float",
                            "type": "number"
                          },
                          "type": "array"
                        },
                        "type": "array"
                      },
                      "source_model": {
                        "type": "string"
                      },
                      "target_model": {
                        "type": "string"
                      }
                    },
                    "required": [
                      "embeddings",
                      "source_model",
                      "target_model"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "data"
                ],
                "type": "object"
              }
            }
          },
          "description": "Translated embeddings"
        },
        "401": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "422": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "429": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        }
      },
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySchemes": {
        "bearerAuth": {
          "description": "UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.",
          "scheme": "bearer",
          "type": "http"
        }
      },
      "securitySource": "definition"
    },
    "reachable": true
  },
  {
    "entity": "convert",
    "accessor": "Convert",
    "op": "create",
    "id": "POST /v1/ephemeral/embed-bridge",
    "contractVersion": 1,
    "kind": "http",
    "path": "/v1/ephemeral/embed-bridge",
    "method": "POST",
    "action": "ephemeral_bridge",
    "args": {},
    "facts": {
      "factSources": {
        "responses": "guide"
      },
      "live": {
        "assert": {
          "equal": {
            "bridge_model": {
              "from": "models",
              "path": "sourceModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "target_model": {
              "from": "models",
              "path": "targetModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            }
          },
          "vectors": {
            "count": 1,
            "dimension": {
              "from": "models",
              "path": "targetDim",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "path": "embeddings"
          }
        },
        "auth": "issued",
        "credential": {
          "from": "key",
          "path": "key"
        },
        "id": "ephemeral-embed-bridge",
        "input": {
          "bridge_model": {
            "from": "models",
            "path": "sourceModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          },
          "target_model": {
            "from": "models",
            "path": "targetModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          },
          "texts": [
            "SDK live coverage test."
          ]
        }
      },
      "operationId": "embedBridgeEphemeral",
      "parameters": [],
      "protocol": "http",
      "requestBody": {
        "content": {
          "application/json": {
            "example": {
              "bridge_model": "alibaba-nlp-gte-large-en-v1.5",
              "target_model": "nomic-embed-text-v1.5",
              "texts": [
                "hello world"
              ]
            },
            "schema": {
              "properties": {
                "bridge_model": {
                  "description": "Embed model used to vectorise the text before translation.",
                  "example": "alibaba-nlp-gte-large-en-v1.5",
                  "type": "string"
                },
                "target_model": {
                  "description": "Model space to translate into.",
                  "example": "nomic-embed-text-v1.5",
                  "type": "string"
                },
                "texts": {
                  "description": "Texts to embed and translate.",
                  "example": [
                    "hello world"
                  ],
                  "items": {
                    "type": "string"
                  },
                  "type": "array"
                }
              },
              "required": [
                "bridge_model",
                "target_model",
                "texts"
              ],
              "type": "object"
            }
          }
        },
        "required": true
      },
      "responses": {
        "200": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "data": {
                    "properties": {
                      "bridge_model": {
                        "type": "string"
                      },
                      "embeddings": {
                        "description": "Translated vectors, in the target model's dimension.",
                        "items": {
                          "description": "A single embedding vector.",
                          "items": {
                            "format": "float",
                            "type": "number"
                          },
                          "type": "array"
                        },
                        "type": "array"
                      },
                      "model": {
                        "type": "string"
                      },
                      "target_model": {
                        "type": "string"
                      }
                    },
                    "required": [
                      "embeddings",
                      "bridge_model",
                      "target_model"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "data"
                ],
                "type": "object"
              }
            }
          },
          "description": "Translated embeddings"
        },
        "401": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "422": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "429": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        }
      },
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySchemes": {
        "bearerAuth": {
          "description": "UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.",
          "scheme": "bearer",
          "type": "http"
        }
      },
      "securitySource": "definition"
    },
    "reachable": true
  },
  {
    "entity": "embed",
    "accessor": "Embed",
    "op": "create",
    "id": "POST /v1/embed",
    "contractVersion": 1,
    "kind": "http",
    "path": "/v1/embed",
    "method": "POST",
    "args": {},
    "facts": {
      "live": {
        "assert": {
          "equal": {
            "model": {
              "from": "models",
              "path": "sourceModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            }
          },
          "vectors": {
            "count": 1,
            "dimension": {
              "from": "models",
              "path": "sourceDim",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "path": "embeddings"
          }
        },
        "auth": "account",
        "id": "account-embed",
        "input": {
          "model": {
            "from": "models",
            "path": "sourceModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          },
          "texts": [
            "SDK live coverage test."
          ]
        }
      },
      "operationId": "createEmbedding",
      "parameters": [],
      "protocol": "http",
      "requestBody": {
        "content": {
          "application/json": {
            "example": {
              "model": "baai-bge-base-en-v1.5",
              "texts": [
                "hello world"
              ]
            },
            "schema": {
              "properties": {
                "model": {
                  "description": "Name of an embed model, as returned by listModels.",
                  "example": "baai-bge-base-en-v1.5",
                  "type": "string"
                },
                "texts": {
                  "description": "Texts to embed. One vector is returned per text, in order.",
                  "example": [
                    "hello world"
                  ],
                  "items": {
                    "type": "string"
                  },
                  "type": "array"
                }
              },
              "required": [
                "model",
                "texts"
              ],
              "type": "object"
            }
          }
        },
        "required": true
      },
      "responses": {
        "200": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "data": {
                    "properties": {
                      "embeddings": {
                        "description": "One vector per input text, in input order.",
                        "items": {
                          "description": "A single embedding vector.",
                          "items": {
                            "format": "float",
                            "type": "number"
                          },
                          "type": "array"
                        },
                        "type": "array"
                      },
                      "model": {
                        "description": "Model that produced the vectors.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "embeddings",
                      "model"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "data"
                ],
                "type": "object"
              }
            }
          },
          "description": "Generated embeddings"
        },
        "401": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "422": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        }
      },
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySchemes": {
        "bearerAuth": {
          "description": "UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.",
          "scheme": "bearer",
          "type": "http"
        }
      },
      "securitySource": "definition"
    },
    "reachable": true
  },
  {
    "entity": "embed",
    "accessor": "Embed",
    "op": "create",
    "id": "POST /v1/ephemeral/embed",
    "contractVersion": 1,
    "kind": "http",
    "path": "/v1/ephemeral/embed",
    "method": "POST",
    "action": "ephemeral",
    "args": {},
    "facts": {
      "live": {
        "assert": {
          "equal": {
            "model": {
              "from": "models",
              "path": "sourceModel",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            }
          },
          "vectors": {
            "count": 1,
            "dimension": {
              "from": "models",
              "path": "sourceDim",
              "related": {
                "foreign": "name",
                "from": "models",
                "local": "sourceModel",
                "where": {
                  "modelType": "embed"
                }
              },
              "where": {
                "modelType": "convert"
              }
            },
            "path": "embeddings"
          }
        },
        "auth": "issued",
        "credential": {
          "from": "key",
          "path": "key"
        },
        "id": "ephemeral-embed",
        "input": {
          "model": {
            "from": "models",
            "path": "sourceModel",
            "related": {
              "foreign": "name",
              "from": "models",
              "local": "sourceModel",
              "where": {
                "modelType": "embed"
              }
            },
            "where": {
              "modelType": "convert"
            }
          },
          "texts": [
            "SDK live coverage test."
          ]
        }
      },
      "operationId": "createEphemeralEmbedding",
      "parameters": [],
      "protocol": "http",
      "requestBody": {
        "content": {
          "application/json": {
            "example": {
              "model": "baai-bge-base-en-v1.5",
              "texts": [
                "hello world"
              ]
            },
            "schema": {
              "properties": {
                "model": {
                  "description": "Name of an embed model, as returned by listModels.",
                  "example": "baai-bge-base-en-v1.5",
                  "type": "string"
                },
                "texts": {
                  "description": "Texts to embed. One vector is returned per text, in order.",
                  "example": [
                    "hello world"
                  ],
                  "items": {
                    "type": "string"
                  },
                  "type": "array"
                }
              },
              "required": [
                "model",
                "texts"
              ],
              "type": "object"
            }
          }
        },
        "required": true
      },
      "responses": {
        "200": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "data": {
                    "properties": {
                      "embeddings": {
                        "description": "One vector per input text, in input order.",
                        "items": {
                          "description": "A single embedding vector.",
                          "items": {
                            "format": "float",
                            "type": "number"
                          },
                          "type": "array"
                        },
                        "type": "array"
                      },
                      "model": {
                        "description": "Model that produced the vectors.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "embeddings",
                      "model"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "data"
                ],
                "type": "object"
              }
            }
          },
          "description": "Generated embeddings"
        },
        "401": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "422": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        },
        "429": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "error": {
                    "properties": {
                      "message": {
                        "description": "Human-readable error detail.",
                        "type": "string"
                      }
                    },
                    "required": [
                      "message"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "description": "Always false on an error.",
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "error"
                ],
                "type": "object"
              }
            }
          },
          "description": "Error"
        }
      },
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySchemes": {
        "bearerAuth": {
          "description": "UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.",
          "scheme": "bearer",
          "type": "http"
        }
      },
      "securitySource": "definition"
    },
    "reachable": true
  },
  {
    "entity": "ephemeral_key",
    "accessor": "EphemeralKey",
    "op": "create",
    "id": "POST /v1/ephemeral/key",
    "contractVersion": 1,
    "kind": "http",
    "path": "/v1/ephemeral/key",
    "method": "POST",
    "args": {},
    "facts": {
      "live": {
        "assert": {
          "nonempty": [
            "key"
          ]
        },
        "auth": "public",
        "id": "key",
        "input": {},
        "retention": "No deletion endpoint; issued key is subject to the service daily allowance"
      },
      "operationId": "createEphemeralKey",
      "parameters": [],
      "protocol": "http",
      "requestBody": {
        "content": {
          "application/json": {
            "example": {},
            "schema": {
              "additionalProperties": false,
              "type": "object"
            }
          }
        },
        "required": false
      },
      "responses": {
        "200": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "data": {
                    "properties": {
                      "dailyLimit": {
                        "description": "Calls permitted per day.",
                        "type": "integer"
                      },
                      "dailyUsed": {
                        "description": "Calls already used today.",
                        "type": "integer"
                      },
                      "key": {
                        "description": "The ephemeral API key, prefixed `eph_`.",
                        "type": "string"
                      },
                      "resetsAt": {
                        "description": "When the daily allowance resets.",
                        "format": "date-time",
                        "type": "string"
                      }
                    },
                    "required": [
                      "key",
                      "dailyLimit",
                      "dailyUsed",
                      "resetsAt"
                    ],
                    "type": "object"
                  },
                  "success": {
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "data"
                ],
                "type": "object"
              }
            }
          },
          "description": "Issued key"
        }
      },
      "security": [],
      "securitySchemes": {
        "bearerAuth": {
          "description": "UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.",
          "scheme": "bearer",
          "type": "http"
        }
      },
      "securitySource": "operation"
    },
    "reachable": true
  },
  {
    "entity": "model",
    "accessor": "Model",
    "op": "list",
    "id": "GET /v1/models",
    "contractVersion": 1,
    "kind": "http",
    "path": "/v1/models",
    "method": "GET",
    "args": {},
    "facts": {
      "factSources": {
        "responses": "guide"
      },
      "live": {
        "assert": {
          "nonempty": [
            ""
          ]
        },
        "auth": "public",
        "id": "models"
      },
      "operationId": "listModels",
      "parameters": [],
      "protocol": "http",
      "responses": {
        "200": {
          "content": {
            "application/json": {
              "schema": {
                "properties": {
                  "data": {
                    "items": {
                      "oneOf": [
                        {
                          "properties": {
                            "eval": {
                              "description": "Retrieval-fidelity metrics for a convert model.",
                              "properties": {
                                "cosine_mean": {
                                  "format": "float",
                                  "type": "number"
                                },
                                "cosine_median": {
                                  "format": "float",
                                  "type": "number"
                                },
                                "cosine_std": {
                                  "format": "float",
                                  "type": "number"
                                },
                                "kendall_p_value": {
                                  "format": "float",
                                  "type": "number"
                                },
                                "kendall_tau": {
                                  "format": "float",
                                  "type": "number"
                                },
                                "mrr": {
                                  "description": "Mean reciprocal rank.",
                                  "format": "float",
                                  "type": "number"
                                },
                                "p_at_1": {
                                  "format": "float",
                                  "type": "number"
                                },
                                "p_at_10": {
                                  "format": "float",
                                  "type": "number"
                                },
                                "p_at_5": {
                                  "format": "float",
                                  "type": "number"
                                }
                              },
                              "type": "object"
                            },
                            "executionProvider": {
                              "description": "Hardware backend, e.g. `cpu`.",
                              "type": "string"
                            },
                            "modelCard": {
                              "additionalProperties": true,
                              "description": "Convert models only: training provenance and architecture detail.",
                              "type": "object"
                            },
                            "modelType": {
                              "description": "`embed` for text-to-vector models, `convert` for space-translation models.",
                              "enum": [
                                "embed",
                                "convert"
                              ],
                              "type": "string"
                            },
                            "name": {
                              "description": "Model identifier used in requests.",
                              "type": "string"
                            },
                            "sequenceLen": {
                              "description": "Embed models only: maximum input sequence length.",
                              "type": "integer"
                            },
                            "sourceDim": {
                              "description": "Convert models only: source vector dimension.",
                              "type": "integer"
                            },
                            "sourceModel": {
                              "description": "Convert models only: the source model space.",
                              "type": "string"
                            },
                            "targetDim": {
                              "description": "Dimension of the produced vectors.",
                              "type": "integer"
                            },
                            "targetModel": {
                              "description": "The model space produced.",
                              "type": "string"
                            }
                          },
                          "required": [
                            "name",
                            "modelType",
                            "targetModel",
                            "targetDim"
                          ],
                          "type": "object"
                        },
                        {
                          "properties": {
                            "executionProvider": {
                              "type": "string"
                            },
                            "modelType": {
                              "enum": [
                                "convert-bridge",
                                "embed-bridge"
                              ],
                              "type": "string"
                            },
                            "name": {
                              "type": "string"
                            },
                            "restrictedTargets": {
                              "items": {
                                "type": "string"
                              },
                              "type": "array"
                            }
                          },
                          "required": [
                            "name",
                            "modelType",
                            "executionProvider"
                          ],
                          "type": "object"
                        }
                      ]
                    },
                    "type": "array"
                  },
                  "success": {
                    "type": "boolean"
                  }
                },
                "required": [
                  "success",
                  "data"
                ],
                "type": "object"
              }
            }
          },
          "description": "Model list"
        }
      },
      "security": [],
      "securitySchemes": {
        "bearerAuth": {
          "description": "UniVec API key, sent as `Authorization: Bearer uv_...`. Ephemeral keys use the `eph_` prefix and are restricted to the /v1/ephemeral/* routes.",
          "scheme": "bearer",
          "type": "http"
        }
      },
      "securitySource": "operation"
    },
    "reachable": true
  }
], 'UNIVEC', { server: {  }, secret: process.env.UNIVEC_SECRET })
})
