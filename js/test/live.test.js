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
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySource": "definition",
      "responses": {
        "200": {
          "description": "Translated embeddings",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "data"
                ],
                "properties": {
                  "success": {
                    "type": "boolean"
                  },
                  "data": {
                    "type": "object",
                    "required": [
                      "embeddings",
                      "source_model",
                      "target_model"
                    ],
                    "properties": {
                      "embeddings": {
                        "type": "array",
                        "description": "Translated vectors, in the target model's dimension.",
                        "items": {
                          "type": "array",
                          "description": "A single embedding vector.",
                          "items": {
                            "type": "number",
                            "format": "float"
                          },
                          "x-ref": "#/components/schemas/Embedding"
                        },
                        "key$": "embeddings"
                      },
                      "source_model": {
                        "type": "string",
                        "key$": "source_model"
                      },
                      "target_model": {
                        "type": "string",
                        "key$": "target_model"
                      }
                    },
                    "index$": 0
                  }
                },
                "x-ref": "#/components/schemas/ConvertResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ConvertResponse"
        },
        "401": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "422": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        }
      }
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
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySource": "definition",
      "responses": {
        "200": {
          "description": "Translated embeddings",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "data"
                ],
                "properties": {
                  "success": {
                    "type": "boolean"
                  },
                  "data": {
                    "type": "object",
                    "required": [
                      "embeddings",
                      "source_model",
                      "target_model"
                    ],
                    "properties": {
                      "embeddings": {
                        "type": "array",
                        "description": "Translated vectors, in the target model's dimension.",
                        "items": {
                          "type": "array",
                          "description": "A single embedding vector.",
                          "items": {
                            "type": "number",
                            "format": "float"
                          },
                          "x-ref": "#/components/schemas/Embedding"
                        },
                        "key$": "embeddings"
                      },
                      "source_model": {
                        "type": "string",
                        "key$": "source_model"
                      },
                      "target_model": {
                        "type": "string",
                        "key$": "target_model"
                      }
                    },
                    "index$": 0
                  }
                },
                "x-ref": "#/components/schemas/ConvertResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ConvertResponse"
        },
        "401": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "422": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        }
      }
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
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySource": "definition",
      "responses": {
        "200": {
          "description": "Translated embeddings",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "data"
                ],
                "properties": {
                  "success": {
                    "type": "boolean"
                  },
                  "data": {
                    "type": "object",
                    "required": [
                      "embeddings",
                      "source_model",
                      "target_model"
                    ],
                    "properties": {
                      "embeddings": {
                        "type": "array",
                        "description": "Translated vectors, in the target model's dimension.",
                        "items": {
                          "type": "array",
                          "description": "A single embedding vector.",
                          "items": {
                            "type": "number",
                            "format": "float"
                          },
                          "x-ref": "#/components/schemas/Embedding"
                        },
                        "key$": "embeddings"
                      },
                      "source_model": {
                        "type": "string",
                        "key$": "source_model"
                      },
                      "target_model": {
                        "type": "string",
                        "key$": "target_model"
                      }
                    },
                    "index$": 0
                  }
                },
                "x-ref": "#/components/schemas/ConvertResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ConvertResponse"
        },
        "401": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "422": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "429": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        }
      }
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
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySource": "definition",
      "responses": {
        "200": {
          "description": "Translated embeddings",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "data"
                ],
                "properties": {
                  "success": {
                    "type": "boolean"
                  },
                  "data": {
                    "type": "object",
                    "required": [
                      "embeddings",
                      "source_model",
                      "target_model"
                    ],
                    "properties": {
                      "embeddings": {
                        "type": "array",
                        "description": "Translated vectors, in the target model's dimension.",
                        "items": {
                          "type": "array",
                          "description": "A single embedding vector.",
                          "items": {
                            "type": "number",
                            "format": "float"
                          },
                          "x-ref": "#/components/schemas/Embedding"
                        },
                        "key$": "embeddings"
                      },
                      "source_model": {
                        "type": "string",
                        "key$": "source_model"
                      },
                      "target_model": {
                        "type": "string",
                        "key$": "target_model"
                      }
                    },
                    "index$": 0
                  }
                },
                "x-ref": "#/components/schemas/ConvertResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ConvertResponse"
        },
        "401": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "422": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "429": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        }
      }
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
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySource": "definition",
      "responses": {
        "200": {
          "description": "Generated embeddings",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "data"
                ],
                "properties": {
                  "success": {
                    "type": "boolean"
                  },
                  "data": {
                    "type": "object",
                    "required": [
                      "embeddings",
                      "model"
                    ],
                    "properties": {
                      "embeddings": {
                        "type": "array",
                        "description": "One vector per input text, in input order.",
                        "items": {
                          "type": "array",
                          "description": "A single embedding vector.",
                          "items": {
                            "type": "number",
                            "format": "float"
                          },
                          "x-ref": "#/components/schemas/Embedding"
                        },
                        "key$": "embeddings"
                      },
                      "model": {
                        "type": "string",
                        "description": "Model that produced the vectors.",
                        "key$": "model"
                      }
                    },
                    "index$": 0
                  }
                },
                "x-ref": "#/components/schemas/EmbedResponse"
              }
            }
          },
          "x-ref": "#/components/responses/EmbedResponse"
        },
        "401": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "422": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        }
      }
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
      "security": [
        {
          "bearerAuth": []
        }
      ],
      "securitySource": "definition",
      "responses": {
        "200": {
          "description": "Generated embeddings",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "data"
                ],
                "properties": {
                  "success": {
                    "type": "boolean"
                  },
                  "data": {
                    "type": "object",
                    "required": [
                      "embeddings",
                      "model"
                    ],
                    "properties": {
                      "embeddings": {
                        "type": "array",
                        "description": "One vector per input text, in input order.",
                        "items": {
                          "type": "array",
                          "description": "A single embedding vector.",
                          "items": {
                            "type": "number",
                            "format": "float"
                          },
                          "x-ref": "#/components/schemas/Embedding"
                        },
                        "key$": "embeddings"
                      },
                      "model": {
                        "type": "string",
                        "description": "Model that produced the vectors.",
                        "key$": "model"
                      }
                    },
                    "index$": 0
                  }
                },
                "x-ref": "#/components/schemas/EmbedResponse"
              }
            }
          },
          "x-ref": "#/components/responses/EmbedResponse"
        },
        "401": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "422": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        },
        "429": {
          "description": "Error",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "error"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "description": "Always false on an error."
                  },
                  "error": {
                    "type": "object",
                    "required": [
                      "message"
                    ],
                    "properties": {
                      "message": {
                        "type": "string",
                        "description": "Human-readable error detail."
                      }
                    }
                  }
                },
                "x-ref": "#/components/schemas/ErrorResponse"
              }
            }
          },
          "x-ref": "#/components/responses/ErrorResponse"
        }
      }
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
        "retention": "No deletion endpoint; issued key is subject to the service daily allowance"
      },
      "security": [],
      "securitySource": "operation",
      "responses": {
        "200": {
          "description": "Issued key",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "data"
                ],
                "properties": {
                  "success": {
                    "type": "boolean"
                  },
                  "data": {
                    "type": "object",
                    "required": [
                      "key",
                      "dailyLimit",
                      "dailyUsed",
                      "resetsAt"
                    ],
                    "properties": {
                      "key": {
                        "type": "string",
                        "description": "The ephemeral API key, prefixed `eph_`.",
                        "key$": "key"
                      },
                      "dailyLimit": {
                        "type": "integer",
                        "description": "Calls permitted per day.",
                        "key$": "dailyLimit"
                      },
                      "dailyUsed": {
                        "type": "integer",
                        "description": "Calls already used today.",
                        "key$": "dailyUsed"
                      },
                      "resetsAt": {
                        "type": "string",
                        "format": "date-time",
                        "description": "When the daily allowance resets.",
                        "key$": "resetsAt"
                      }
                    },
                    "index$": 0
                  }
                },
                "x-ref": "#/components/schemas/EphemeralKeyResponse"
              }
            }
          }
        }
      }
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
      "live": {
        "assert": {
          "nonempty": [
            ""
          ]
        },
        "auth": "public",
        "id": "models"
      },
      "security": [],
      "securitySource": "operation",
      "responses": {
        "200": {
          "description": "Model list",
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": [
                  "success",
                  "data"
                ],
                "properties": {
                  "success": {
                    "type": "boolean",
                    "key$": "success"
                  },
                  "data": {
                    "items": {
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
                          "type": "object",
                          "x-ref": "#/components/schemas/ModelEval",
                          "key$": "eval"
                        },
                        "executionProvider": {
                          "description": "Hardware backend, e.g. `cpu`.",
                          "type": "string",
                          "key$": "executionProvider"
                        },
                        "modelCard": {
                          "additionalProperties": true,
                          "description": "Convert models only: training provenance and architecture detail.",
                          "type": "object",
                          "key$": "modelCard"
                        },
                        "modelType": {
                          "description": "`embed` for text-to-vector models, `convert` for space-translation models.",
                          "enum": [
                            "embed",
                            "convert"
                          ],
                          "type": "string",
                          "key$": "modelType"
                        },
                        "name": {
                          "description": "Model identifier used in requests.",
                          "type": "string",
                          "key$": "name"
                        },
                        "sequenceLen": {
                          "description": "Embed models only: maximum input sequence length.",
                          "type": "integer",
                          "key$": "sequenceLen"
                        },
                        "sourceDim": {
                          "description": "Convert models only: source vector dimension.",
                          "type": "integer",
                          "key$": "sourceDim"
                        },
                        "sourceModel": {
                          "description": "Convert models only: the source model space.",
                          "type": "string",
                          "key$": "sourceModel"
                        },
                        "targetDim": {
                          "description": "Dimension of the produced vectors.",
                          "type": "integer",
                          "key$": "targetDim"
                        },
                        "targetModel": {
                          "description": "The model space produced.",
                          "type": "string",
                          "key$": "targetModel"
                        }
                      },
                      "required": [
                        "name",
                        "modelType",
                        "targetModel",
                        "targetDim"
                      ],
                      "type": "object",
                      "x-ref": "#/components/schemas/Model",
                      "index$": 0
                    },
                    "type": "array",
                    "key$": "data"
                  }
                },
                "x-ref": "#/components/schemas/ModelListResponse"
              }
            }
          }
        }
      }
    },
    "reachable": true
  }
], 'UNIVEC', { server: {  }, secret: process.env.UNIVEC_SECRET })
})
