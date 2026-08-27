import 'feature/base/BaseFeature.dart';
import 'feature/audit/AuditFeature.dart';
import 'feature/cache/CacheFeature.dart';
import 'feature/clienttrack/ClienttrackFeature.dart';
import 'feature/cost/CostFeature.dart';
import 'feature/debug/DebugFeature.dart';
import 'feature/idempotency/IdempotencyFeature.dart';
import 'feature/log/LogFeature.dart';
import 'feature/metrics/MetricsFeature.dart';
import 'feature/netsim/NetsimFeature.dart';
import 'feature/paging/PagingFeature.dart';
import 'feature/proxy/ProxyFeature.dart';
import 'feature/ratelimit/RatelimitFeature.dart';
import 'feature/rbac/RbacFeature.dart';
import 'feature/retry/RetryFeature.dart';
import 'feature/streaming/StreamingFeature.dart';
import 'feature/telemetry/TelemetryFeature.dart';
import 'feature/test/TestFeature.dart';
import 'feature/timeout/TimeoutFeature.dart';


// ignore: non_constant_identifier_names
final Map<String, BaseFeature Function()> FEATURE_CLASS = {
    'audit': () => AuditFeature(),
  'cache': () => CacheFeature(),
  'clienttrack': () => ClienttrackFeature(),
  'cost': () => CostFeature(),
  'debug': () => DebugFeature(),
  'idempotency': () => IdempotencyFeature(),
  'log': () => LogFeature(),
  'metrics': () => MetricsFeature(),
  'netsim': () => NetsimFeature(),
  'paging': () => PagingFeature(),
  'proxy': () => ProxyFeature(),
  'ratelimit': () => RatelimitFeature(),
  'rbac': () => RbacFeature(),
  'retry': () => RetryFeature(),
  'streaming': () => StreamingFeature(),
  'telemetry': () => TelemetryFeature(),
  'test': () => TestFeature(),
  'timeout': () => TimeoutFeature(),

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
        'audit': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'actor': 'anonymous',
        'max': 1000,
      },
      'transport': 'none',
    },
    'cache': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'max': 256,
        'methods': <dynamic>[
          'GET',
        ],
        'ttl': 5000,
      },
      'transport': 'wrap',
    },
    'clienttrack': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'clientVersion': '0.0.1',
      },
      'transport': 'none',
    },
    'cost': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'budget': 0,
        'currency': 'USD',
        'header': '',
        'onBudget': 'warn',
        'path': '',
        'perUnit': 0,
        'rates': <String, dynamic>{},
        'unit': 0,
      },
      'transport': 'wrap',
    },
    'debug': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'max': 100,
        'redact': <dynamic>[
          'authorization',
          'cookie',
          'set-cookie',
          'api-key',
          'apikey',
          'x-api-key',
          'idempotency-key',
        ],
      },
      'transport': 'none',
    },
    'idempotency': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'header': 'Idempotency-Key',
        'methods': <dynamic>[
          'POST',
          'PUT',
          'PATCH',
          'DELETE',
        ],
        'ops': <dynamic>[
          'create',
          'update',
          'remove',
        ],
      },
      'transport': 'none',
    },
    'log': <String, dynamic>{
      'options': <String, dynamic>{
        'active': true,
      },
      'transport': 'none',
    },
    'metrics': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
      },
      'transport': 'none',
    },
    'netsim': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'errorTimes': 0,
        'failEvery': 0,
        'failRate': 0,
        'failStatus': 503,
        'failTimes': 0,
        'latency': 0,
        'offline': false,
        'rateLimitTimes': 0,
        'retryAfter': 0,
        'seed': 1,
      },
      'transport': 'wrap',
    },
    'paging': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'afterVar': 'after',
        'cursorParam': 'cursor',
        'firstVar': 'first',
        'limitParam': 'limit',
        'pageParam': 'page',
        'startPage': 1,
      },
      'transport': 'none',
    },
    'proxy': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'fromEnv': false,
        'noProxy': <dynamic>[],
        'url': '',
      },
      'transport': 'wrap',
    },
    'ratelimit': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'burst': 5,
        'rate': 5,
      },
      'transport': 'wrap',
    },
    'rbac': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'deny': false,
        'permissions': <dynamic>[],
        'rules': <String, dynamic>{},
      },
      'transport': 'none',
    },
    'retry': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'factor': 2,
        'maxDelay': 2000,
        'minDelay': 50,
        'retries': 2,
        'statuses': <dynamic>[
          408,
          425,
          429,
          500,
          502,
          503,
          504,
        ],
      },
      'transport': 'wrap',
    },
    'streaming': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'chunkDelay': 0,
        'chunkSize': 0,
      },
      'transport': 'none',
    },
    'telemetry': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
      },
      'transport': 'none',
    },
    'test': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
      },
      'transport': 'base',
    },
    'timeout': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'ms': 30000,
      },
      'transport': 'wrap',
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
