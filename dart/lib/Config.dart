import 'feature/base/BaseFeature.dart';
import 'feature/test/TestFeature.dart';


// ignore: non_constant_identifier_names
final Map<String, BaseFeature Function()> FEATURE_CLASS = {
    'test': () => TestFeature(),

};

class Config {
  BaseFeature makeFeature(String fn) {
    final fc = FEATURE_CLASS[fn];
    if (null == fc) {
      // TODO: errors etc
      throw StateError('Unknown feature: ' + fn);
    }
    return fc();
  }

  // False for a feature added at runtime via options.extend (station's
  // adopt path) - the constructor uses this to skip makeFeature for names
  // no generated class backs.
  bool hasFeature(String fn) => null != FEATURE_CLASS[fn];

  final Map<String, dynamic> main = <String, dynamic>{
    'name': 'Univec',
        'slug': 'univec',
    'version': '0.1.1',
    'target': 'dart',

  };

  final Map<String, dynamic> feature = <String, dynamic>{
        'test': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
      },
      'transport': 'base',
    },

  };

  // Rendered whole from the canonical config definition rather than assembled
  // slot by slot. Assembling it here meant `options.server` - the OpenAPI
  // server-variable defaults - was simply absent from this branch, so a
  // templated server URL produced a different config either side of the
  // threshold.
  final Map<String, dynamic> options = <String, dynamic>{
    'base': 'https://api.univec.ai',
    'auth': <String, dynamic>{
      'prefix': 'Bearer',
    },
    'headers': <String, dynamic>{
      'content-type': 'application/json',
    },
    'entity': <String, dynamic>{
      'convert': <String, dynamic>{},
      'embed': <String, dynamic>{},
      'ephemeral_key': <String, dynamic>{},
      'model': <String, dynamic>{},
    },
  };

  final Map<String, dynamic> entity = <String, dynamic>{
    'convert': <String, dynamic>{
      'fields': <dynamic>[
        <String, dynamic>{
          'name': 'bridge_model',
          'req': true,
          'short': 'Embed model used to vectorise the text before translation.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'embeddings',
          'req': true,
          'short': 'Translated vectors, in the target model\'s dimension.',
          'type': '`\$ARRAY`',
        },
        <String, dynamic>{
          'name': 'source_model',
          'req': true,
          'short': 'Model space the supplied vectors are currently in.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'target_model',
          'req': true,
          'short': 'Model space to translate into.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'texts',
          'req': true,
          'short': 'Texts to embed and translate.',
          'type': '`\$ARRAY`',
        },
      ],
      'name': 'convert',
      'op': <String, dynamic>{
        'create': <String, dynamic>{
          'input': 'data',
          'name': 'create',
          'points': <dynamic>[
            <String, dynamic>{
              'args': <String, dynamic>{},
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/convert',
              'parts': <dynamic>[
                'v1',
                'convert',
              ],
              'select': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
            },
            <String, dynamic>{
              'args': <String, dynamic>{},
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/embed-bridge',
              'parts': <dynamic>[
                'v1',
                'embed-bridge',
              ],
              'select': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
            },
            <String, dynamic>{
              'args': <String, dynamic>{},
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/ephemeral/convert',
              'parts': <dynamic>[
                'v1',
                'ephemeral',
                'convert',
              ],
              'select': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
            },
            <String, dynamic>{
              'args': <String, dynamic>{},
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/ephemeral/embed-bridge',
              'parts': <dynamic>[
                'v1',
                'ephemeral',
                'embed-bridge',
              ],
              'select': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
            },
          ],
        },
      },
      'relations': <String, dynamic>{
        'ancestors': <dynamic>[],
      },
    },
    'embed': <String, dynamic>{
      'fields': <dynamic>[
        <String, dynamic>{
          'name': 'embeddings',
          'req': true,
          'short': 'One vector per input text, in input order.',
          'type': '`\$ARRAY`',
        },
        <String, dynamic>{
          'name': 'model',
          'req': true,
          'short': 'Model that produced the vectors.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'texts',
          'req': true,
          'short': 'Texts to embed.',
          'type': '`\$ARRAY`',
        },
      ],
      'name': 'embed',
      'op': <String, dynamic>{
        'create': <String, dynamic>{
          'input': 'data',
          'name': 'create',
          'points': <dynamic>[
            <String, dynamic>{
              'args': <String, dynamic>{},
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/embed',
              'parts': <dynamic>[
                'v1',
                'embed',
              ],
              'select': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
            },
            <String, dynamic>{
              'args': <String, dynamic>{},
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/ephemeral/embed',
              'parts': <dynamic>[
                'v1',
                'ephemeral',
                'embed',
              ],
              'select': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
            },
          ],
        },
      },
      'relations': <String, dynamic>{
        'ancestors': <dynamic>[],
      },
    },
    'ephemeral_key': <String, dynamic>{
      'fields': <dynamic>[
        <String, dynamic>{
          'name': 'dailyLimit',
          'req': true,
          'short': 'Calls permitted per day.',
          'type': '`\$INTEGER`',
        },
        <String, dynamic>{
          'name': 'dailyUsed',
          'req': true,
          'short': 'Calls already used today.',
          'type': '`\$INTEGER`',
        },
        <String, dynamic>{
          'name': 'key',
          'req': true,
          'short': 'The ephemeral API key, prefixed `eph_`.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'resetsAt',
          'req': true,
          'short': 'When the daily allowance resets.',
          'type': '`\$STRING`',
        },
      ],
      'name': 'ephemeral_key',
      'op': <String, dynamic>{
        'create': <String, dynamic>{
          'input': 'data',
          'name': 'create',
          'points': <dynamic>[
            <String, dynamic>{
              'args': <String, dynamic>{},
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/ephemeral/key',
              'parts': <dynamic>[
                'v1',
                'ephemeral',
                'key',
              ],
              'select': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
            },
          ],
        },
      },
      'relations': <String, dynamic>{
        'ancestors': <dynamic>[],
      },
    },
    'model': <String, dynamic>{
      'fields': <dynamic>[
        <String, dynamic>{
          'name': 'eval',
          'short': 'Retrieval-fidelity metrics for a convert model.',
          'type': '`\$OBJECT`',
        },
        <String, dynamic>{
          'name': 'executionProvider',
          'short': 'Hardware backend, e.g.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'modelCard',
          'short': 'Convert models only: training provenance and architecture detail.',
          'type': '`\$OBJECT`',
        },
        <String, dynamic>{
          'name': 'modelType',
          'req': true,
          'short': '`embed` for text-to-vector models, `convert` for space-translation models.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'name',
          'req': true,
          'short': 'Model identifier used in requests.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'sequenceLen',
          'short': 'Embed models only: maximum input sequence length.',
          'type': '`\$INTEGER`',
        },
        <String, dynamic>{
          'name': 'sourceDim',
          'short': 'Convert models only: source vector dimension.',
          'type': '`\$INTEGER`',
        },
        <String, dynamic>{
          'name': 'sourceModel',
          'short': 'Convert models only: the source model space.',
          'type': '`\$STRING`',
        },
        <String, dynamic>{
          'name': 'targetDim',
          'req': true,
          'short': 'Dimension of the produced vectors.',
          'type': '`\$INTEGER`',
        },
        <String, dynamic>{
          'name': 'targetModel',
          'req': true,
          'short': 'The model space produced.',
          'type': '`\$STRING`',
        },
      ],
      'name': 'model',
      'op': <String, dynamic>{
        'list': <String, dynamic>{
          'input': 'data',
          'name': 'list',
          'points': <dynamic>[
            <String, dynamic>{
              'args': <String, dynamic>{},
              'kind': 'http',
              'method': 'GET',
              'orig': '/v1/models',
              'parts': <dynamic>[
                'v1',
                'models',
              ],
              'select': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
            },
          ],
        },
      },
      'relations': <String, dynamic>{
        'ancestors': <dynamic>[],
      },
    },
  };

  // The pipeline context carries the config as a plain map.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'main': main,
        'feature': feature,
        'options': options,
        'entity': entity,
      };
}

final config = Config();
