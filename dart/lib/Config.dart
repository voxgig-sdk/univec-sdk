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
import 'feature/secrets/SecretsFeature.dart';
import 'feature/streaming/StreamingFeature.dart';
import 'feature/telemetry/TelemetryFeature.dart';
import 'feature/test/TestFeature.dart';
import 'feature/timeout/TimeoutFeature.dart';

import 'feature/secrets/sekreto/plugins/boru.dart' show boru;
import 'feature/secrets/sekreto/plugins/hashicorp.dart' show hashicorp;


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
  'secrets': () => SecretsFeature(),
  'streaming': () => StreamingFeature(),
  'telemetry': () => TelemetryFeature(),
  'test': () => TestFeature(),
  'timeout': () => TimeoutFeature(),

};

// Per-feature plugin DEFINITIONS (voxgig/plugin `Definition` values), from
// the model's active plugin groups. A feature that takes a `plugins` option
// (secrets over sekreto) reads its own entry; a feature with no plugins has
// none. The named `show` imports above make each definition statically
// reachable, so an SDK carries exactly the plugin libraries its model
// selects - the same leanness the old side-effect registry bought, without
// a registry.
//
// Emitted UNCONDITIONALLY, empty when no group is active: SecretsFeature
// imports this name, and the feature source can be present in a tree whose
// model selects no plugin group at all. An emission conditional on the map
// having entries would make that tree fail `dart analyze`.
//
// ignore: non_constant_identifier_names
final Map<String, List<dynamic>> FEATURE_PLUGINS = <String, List<dynamic>>{
    'secrets': [boru, hashicorp],

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
    'version': '0.1.2',
    'target': 'dart',

  };

  final Map<String, dynamic> feature = <String, dynamic>{
        'audit': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'actor': 'anonymous',
        'max': 1000,
      },
      'optspec': <String, dynamic>{
        'now': '`\$FUNCTION`',
        'sink': '`\$FUNCTION`',
      },
      'strict': false,
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
      'optspec': <String, dynamic>{
        'now': '`\$FUNCTION`',
      },
      'strict': false,
      'transport': 'wrap',
    },
    'clienttrack': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'clientVersion': '0.0.1',
      },
      'optspec': <String, dynamic>{
        'clientName': '`\$STRING`',
        'clientVersion': '`\$STRING`',
        'headers': '`\$MAP`',
        'idgen': '`\$FUNCTION`',
        'sessionId': '`\$STRING`',
      },
      'strict': false,
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
      'optspec': <String, dynamic>{
        'actor': '`\$STRING`',
        'sink': '`\$FUNCTION`',
      },
      'strict': false,
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
      'optspec': <String, dynamic>{
        'now': '`\$FUNCTION`',
        'onEntry': '`\$FUNCTION`',
      },
      'strict': false,
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
      'optspec': <String, dynamic>{
        'keygen': '`\$FUNCTION`',
      },
      'strict': false,
      'transport': 'none',
    },
    'log': <String, dynamic>{
      'options': <String, dynamic>{
        'active': true,
      },
      'optspec': <String, dynamic>{
        'level': '`\$STRING`',
        'logger': '`\$ANY`',
      },
      'strict': false,
      'transport': 'none',
    },
    'metrics': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
      },
      'optspec': <String, dynamic>{
        'now': '`\$FUNCTION`',
      },
      'strict': false,
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
      'optspec': <String, dynamic>{
        'latency': <dynamic>[
          '`\$ONE`',
          '`\$NUMBER`',
          '`\$MAP`',
        ],
        'sleep': '`\$FUNCTION`',
      },
      'strict': false,
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
      'optspec': <String, dynamic>{
        'limit': '`\$NUMBER`',
        'ops': '`\$LIST`',
      },
      'strict': false,
      'transport': 'none',
    },
    'proxy': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'fromEnv': false,
        'noProxy': <dynamic>[],
        'url': '',
      },
      'optspec': <String, dynamic>{
        'agent': '`\$FUNCTION`',
      },
      'strict': false,
      'transport': 'wrap',
    },
    'ratelimit': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'burst': 5,
        'rate': 5,
      },
      'optspec': <String, dynamic>{
        'now': '`\$FUNCTION`',
        'sleep': '`\$FUNCTION`',
      },
      'strict': false,
      'transport': 'wrap',
    },
    'rbac': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'deny': false,
        'permissions': <dynamic>[],
        'rules': <String, dynamic>{},
      },
      'optspec': <String, dynamic>{},
      'strict': false,
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
      'optspec': <String, dynamic>{
        'jitter': '`\$BOOLEAN`',
        'sleep': '`\$FUNCTION`',
      },
      'strict': false,
      'transport': 'wrap',
    },
    'secrets': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'cache': true,
        'exchange': <String, dynamic>{
          'active': false,
          'method': 'POST',
          'path': 'auth/token',
          'refresh': '',
          'request': 'refresh_token',
          'response': 'access_token',
          'retries': 1,
          'statuses': <dynamic>[
            401,
          ],
        },
        'name': 'univec',
        'providers': <dynamic>[
          <String, dynamic>{
            'kind': 'boru',
            'namespace': 'sdk',
          },
        ],
      },
      'optspec': <String, dynamic>{},
      'strict': false,
      'transport': 'wrap',
    },
    'streaming': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'chunkDelay': 0,
        'chunkSize': 0,
      },
      'optspec': <String, dynamic>{
        'ops': '`\$LIST`',
        'sleep': '`\$FUNCTION`',
      },
      'strict': false,
      'transport': 'none',
    },
    'telemetry': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
      },
      'optspec': <String, dynamic>{
        'exporter': '`\$FUNCTION`',
        'headers': '`\$MAP`',
        'idgen': '`\$FUNCTION`',
        'now': '`\$FUNCTION`',
      },
      'strict': false,
      'transport': 'none',
    },
    'test': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
      },
      'optspec': <String, dynamic>{
        'entity': '`\$MAP`',
        'net': '`\$MAP`',
      },
      'strict': false,
      'transport': 'base',
    },
    'timeout': <String, dynamic>{
      'options': <String, dynamic>{
        'active': false,
        'ms': 30000,
      },
      'optspec': <String, dynamic>{
        'clearTimer': '`\$FUNCTION`',
        'now': '`\$FUNCTION`',
        'setTimer': '`\$FUNCTION`',
      },
      'strict': false,
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
          'name': 'embeddings',
          'title': 'Embeddings',
          'type': '`\$ARRAY`',
          'req': true,
          'short': 'Translated vectors, in the target model\'s dimension.',
        },
        <String, dynamic>{
          'name': 'source_model',
          'title': 'Source Model',
          'type': '`\$STRING`',
          'req': true,
          'short': 'Model space the supplied vectors are currently in.',
        },
        <String, dynamic>{
          'name': 'target_model',
          'title': 'Target Model',
          'type': '`\$STRING`',
          'req': true,
          'short': 'Model space to translate into.',
        },
      ],
      'name': 'convert',
      'op': <String, dynamic>{
        'create': <String, dynamic>{
          'input': 'data',
          'name': 'create',
          'points': <dynamic>[
            <String, dynamic>{
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/convert',
              'segments': <dynamic>[
                <String, dynamic>{
                  'lit': 'v1',
                },
                <String, dynamic>{
                  'lit': 'convert',
                },
              ],
              'parts': <dynamic>[
                'v1',
                'convert',
              ],
              'rename': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
              'args': <String, dynamic>{},
              'select': <String, dynamic>{},
              'live': <String, dynamic>{
                'assert': <String, dynamic>{
                  'equal': <String, dynamic>{
                    'source_model': <String, dynamic>{
                      'from': 'models',
                      'path': 'sourceModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'target_model': <String, dynamic>{
                      'from': 'models',
                      'path': 'targetModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                  },
                  'vectors': <String, dynamic>{
                    'count': 1,
                    'dimension': <String, dynamic>{
                      'from': 'models',
                      'path': 'targetDim',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'path': 'embeddings',
                  },
                },
                'auth': 'account',
                'id': 'account-convert',
                'input': <String, dynamic>{
                  'embeddings': <String, dynamic>{
                    'from': 'account-embed',
                    'path': 'embeddings',
                  },
                  'source_model': <String, dynamic>{
                    'from': 'models',
                    'path': 'sourceModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                  'target_model': <String, dynamic>{
                    'from': 'models',
                    'path': 'targetModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                },
              },
              'response': <String, dynamic>{
                'kind': 'json',
                'media': 'application/json',
              },
            },
            <String, dynamic>{
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/embed-bridge',
              'segments': <dynamic>[
                <String, dynamic>{
                  'lit': 'v1',
                },
                <String, dynamic>{
                  'lit': 'embed-bridge',
                },
              ],
              'parts': <dynamic>[
                'v1',
                'embed-bridge',
              ],
              'rename': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
              'args': <String, dynamic>{},
              'select': <String, dynamic>{
                '\$action': 'bridge',
              },
              'live': <String, dynamic>{
                'assert': <String, dynamic>{
                  'equal': <String, dynamic>{
                    'bridge_model': <String, dynamic>{
                      'from': 'models',
                      'path': 'sourceModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'target_model': <String, dynamic>{
                      'from': 'models',
                      'path': 'targetModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                  },
                  'vectors': <String, dynamic>{
                    'count': 1,
                    'dimension': <String, dynamic>{
                      'from': 'models',
                      'path': 'targetDim',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'path': 'embeddings',
                  },
                },
                'auth': 'account',
                'id': 'account-embed-bridge',
                'input': <String, dynamic>{
                  'bridge_model': <String, dynamic>{
                    'from': 'models',
                    'path': 'sourceModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                  'target_model': <String, dynamic>{
                    'from': 'models',
                    'path': 'targetModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                  'texts': <dynamic>[
                    'SDK live coverage test.',
                  ],
                },
              },
              'response': <String, dynamic>{
                'kind': 'json',
                'media': 'application/json',
              },
            },
            <String, dynamic>{
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/ephemeral/convert',
              'segments': <dynamic>[
                <String, dynamic>{
                  'lit': 'v1',
                },
                <String, dynamic>{
                  'lit': 'ephemeral',
                },
                <String, dynamic>{
                  'lit': 'convert',
                },
              ],
              'parts': <dynamic>[
                'v1',
                'ephemeral',
                'convert',
              ],
              'rename': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
              'args': <String, dynamic>{},
              'select': <String, dynamic>{
                '\$action': 'ephemeral',
              },
              'live': <String, dynamic>{
                'assert': <String, dynamic>{
                  'equal': <String, dynamic>{
                    'source_model': <String, dynamic>{
                      'from': 'models',
                      'path': 'sourceModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'target_model': <String, dynamic>{
                      'from': 'models',
                      'path': 'targetModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                  },
                  'vectors': <String, dynamic>{
                    'count': 1,
                    'dimension': <String, dynamic>{
                      'from': 'models',
                      'path': 'targetDim',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'path': 'embeddings',
                  },
                },
                'auth': 'issued',
                'credential': <String, dynamic>{
                  'from': 'key',
                  'path': 'key',
                },
                'id': 'ephemeral-convert',
                'input': <String, dynamic>{
                  'embeddings': <String, dynamic>{
                    'from': 'ephemeral-embed',
                    'path': 'embeddings',
                  },
                  'source_model': <String, dynamic>{
                    'from': 'models',
                    'path': 'sourceModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                  'target_model': <String, dynamic>{
                    'from': 'models',
                    'path': 'targetModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                },
              },
              'response': <String, dynamic>{
                'kind': 'json',
                'media': 'application/json',
              },
            },
            <String, dynamic>{
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/ephemeral/embed-bridge',
              'segments': <dynamic>[
                <String, dynamic>{
                  'lit': 'v1',
                },
                <String, dynamic>{
                  'lit': 'ephemeral',
                },
                <String, dynamic>{
                  'lit': 'embed-bridge',
                },
              ],
              'parts': <dynamic>[
                'v1',
                'ephemeral',
                'embed-bridge',
              ],
              'rename': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
              'args': <String, dynamic>{},
              'select': <String, dynamic>{
                '\$action': 'ephemeral_bridge',
              },
              'live': <String, dynamic>{
                'assert': <String, dynamic>{
                  'equal': <String, dynamic>{
                    'bridge_model': <String, dynamic>{
                      'from': 'models',
                      'path': 'sourceModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'target_model': <String, dynamic>{
                      'from': 'models',
                      'path': 'targetModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                  },
                  'vectors': <String, dynamic>{
                    'count': 1,
                    'dimension': <String, dynamic>{
                      'from': 'models',
                      'path': 'targetDim',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'path': 'embeddings',
                  },
                },
                'auth': 'issued',
                'credential': <String, dynamic>{
                  'from': 'key',
                  'path': 'key',
                },
                'id': 'ephemeral-embed-bridge',
                'input': <String, dynamic>{
                  'bridge_model': <String, dynamic>{
                    'from': 'models',
                    'path': 'sourceModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                  'target_model': <String, dynamic>{
                    'from': 'models',
                    'path': 'targetModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                  'texts': <dynamic>[
                    'SDK live coverage test.',
                  ],
                },
              },
              'response': <String, dynamic>{
                'kind': 'json',
                'media': 'application/json',
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
          'title': 'Embeddings',
          'type': '`\$ARRAY`',
          'req': true,
          'short': 'One vector per input text, in input order.',
        },
        <String, dynamic>{
          'name': 'model',
          'title': 'Model',
          'type': '`\$STRING`',
          'req': true,
          'short': 'Model that produced the vectors.',
        },
        <String, dynamic>{
          'name': 'texts',
          'title': 'Texts',
          'type': '`\$ARRAY`',
          'req': true,
          'short': 'Texts to embed.',
        },
      ],
      'name': 'embed',
      'op': <String, dynamic>{
        'create': <String, dynamic>{
          'input': 'data',
          'name': 'create',
          'points': <dynamic>[
            <String, dynamic>{
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/embed',
              'segments': <dynamic>[
                <String, dynamic>{
                  'lit': 'v1',
                },
                <String, dynamic>{
                  'lit': 'embed',
                },
              ],
              'parts': <dynamic>[
                'v1',
                'embed',
              ],
              'rename': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
              'args': <String, dynamic>{},
              'select': <String, dynamic>{},
              'live': <String, dynamic>{
                'assert': <String, dynamic>{
                  'equal': <String, dynamic>{
                    'model': <String, dynamic>{
                      'from': 'models',
                      'path': 'sourceModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                  },
                  'vectors': <String, dynamic>{
                    'count': 1,
                    'dimension': <String, dynamic>{
                      'from': 'models',
                      'path': 'sourceDim',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'path': 'embeddings',
                  },
                },
                'auth': 'account',
                'id': 'account-embed',
                'input': <String, dynamic>{
                  'model': <String, dynamic>{
                    'from': 'models',
                    'path': 'sourceModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                  'texts': <dynamic>[
                    'SDK live coverage test.',
                  ],
                },
              },
              'response': <String, dynamic>{
                'kind': 'json',
                'media': 'application/json',
              },
            },
            <String, dynamic>{
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/ephemeral/embed',
              'segments': <dynamic>[
                <String, dynamic>{
                  'lit': 'v1',
                },
                <String, dynamic>{
                  'lit': 'ephemeral',
                },
                <String, dynamic>{
                  'lit': 'embed',
                },
              ],
              'parts': <dynamic>[
                'v1',
                'ephemeral',
                'embed',
              ],
              'rename': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
              'args': <String, dynamic>{},
              'select': <String, dynamic>{
                '\$action': 'ephemeral',
              },
              'live': <String, dynamic>{
                'assert': <String, dynamic>{
                  'equal': <String, dynamic>{
                    'model': <String, dynamic>{
                      'from': 'models',
                      'path': 'sourceModel',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                  },
                  'vectors': <String, dynamic>{
                    'count': 1,
                    'dimension': <String, dynamic>{
                      'from': 'models',
                      'path': 'sourceDim',
                      'related': <String, dynamic>{
                        'foreign': 'name',
                        'from': 'models',
                        'local': 'sourceModel',
                        'where': <String, dynamic>{
                          'modelType': 'embed',
                        },
                      },
                      'where': <String, dynamic>{
                        'modelType': 'convert',
                      },
                    },
                    'path': 'embeddings',
                  },
                },
                'auth': 'issued',
                'credential': <String, dynamic>{
                  'from': 'key',
                  'path': 'key',
                },
                'id': 'ephemeral-embed',
                'input': <String, dynamic>{
                  'model': <String, dynamic>{
                    'from': 'models',
                    'path': 'sourceModel',
                    'related': <String, dynamic>{
                      'foreign': 'name',
                      'from': 'models',
                      'local': 'sourceModel',
                      'where': <String, dynamic>{
                        'modelType': 'embed',
                      },
                    },
                    'where': <String, dynamic>{
                      'modelType': 'convert',
                    },
                  },
                  'texts': <dynamic>[
                    'SDK live coverage test.',
                  ],
                },
              },
              'response': <String, dynamic>{
                'kind': 'json',
                'media': 'application/json',
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
          'title': 'Daily Limit',
          'type': '`\$INTEGER`',
          'req': true,
          'short': 'Calls permitted per day.',
        },
        <String, dynamic>{
          'name': 'dailyUsed',
          'title': 'Daily Used',
          'type': '`\$INTEGER`',
          'req': true,
          'short': 'Calls already used today.',
        },
        <String, dynamic>{
          'name': 'key',
          'title': 'Key',
          'type': '`\$STRING`',
          'req': true,
          'short': 'The ephemeral API key, prefixed `eph_`.',
        },
        <String, dynamic>{
          'name': 'resetsAt',
          'title': 'Resets At',
          'type': '`\$STRING`',
          'req': true,
          'short': 'When the daily allowance resets.',
          'format': 'date-time',
        },
      ],
      'name': 'ephemeral_key',
      'op': <String, dynamic>{
        'create': <String, dynamic>{
          'input': 'data',
          'name': 'create',
          'points': <dynamic>[
            <String, dynamic>{
              'kind': 'http',
              'method': 'POST',
              'orig': '/v1/ephemeral/key',
              'segments': <dynamic>[
                <String, dynamic>{
                  'lit': 'v1',
                },
                <String, dynamic>{
                  'lit': 'ephemeral',
                },
                <String, dynamic>{
                  'lit': 'key',
                },
              ],
              'parts': <dynamic>[
                'v1',
                'ephemeral',
                'key',
              ],
              'rename': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
              'args': <String, dynamic>{},
              'select': <String, dynamic>{},
              'live': <String, dynamic>{
                'assert': <String, dynamic>{
                  'nonempty': <dynamic>[
                    'key',
                  ],
                },
                'auth': 'public',
                'id': 'key',
                'retention': 'No deletion endpoint; issued key is subject to the service daily allowance',
              },
              'response': <String, dynamic>{
                'kind': 'json',
                'media': 'application/json',
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
          'title': 'Eval',
          'type': '`\$OBJECT`',
          'short': 'Retrieval-fidelity metrics for a convert model.',
        },
        <String, dynamic>{
          'name': 'executionProvider',
          'title': 'Execution Provider',
          'type': '`\$STRING`',
          'short': 'Hardware backend, e.g.',
        },
        <String, dynamic>{
          'name': 'modelCard',
          'title': 'Model Card',
          'type': '`\$OBJECT`',
          'short': 'Convert models only: training provenance and architecture detail.',
        },
        <String, dynamic>{
          'name': 'modelType',
          'title': 'Model Type',
          'type': '`\$STRING`',
          'req': true,
          'short': '`embed` for text-to-vector models, `convert` for space-translation models.',
        },
        <String, dynamic>{
          'name': 'name',
          'title': 'Name',
          'type': '`\$STRING`',
          'req': true,
          'short': 'Model identifier used in requests.',
        },
        <String, dynamic>{
          'name': 'sequenceLen',
          'title': 'Sequence Len',
          'type': '`\$INTEGER`',
          'short': 'Embed models only: maximum input sequence length.',
        },
        <String, dynamic>{
          'name': 'sourceDim',
          'title': 'Source Dim',
          'type': '`\$INTEGER`',
          'short': 'Convert models only: source vector dimension.',
        },
        <String, dynamic>{
          'name': 'sourceModel',
          'title': 'Source Model',
          'type': '`\$STRING`',
          'short': 'Convert models only: the source model space.',
        },
        <String, dynamic>{
          'name': 'targetDim',
          'title': 'Target Dim',
          'type': '`\$INTEGER`',
          'req': true,
          'short': 'Dimension of the produced vectors.',
        },
        <String, dynamic>{
          'name': 'targetModel',
          'title': 'Target Model',
          'type': '`\$STRING`',
          'req': true,
          'short': 'The model space produced.',
        },
      ],
      'name': 'model',
      'op': <String, dynamic>{
        'list': <String, dynamic>{
          'input': 'data',
          'name': 'list',
          'points': <dynamic>[
            <String, dynamic>{
              'kind': 'http',
              'method': 'GET',
              'orig': '/v1/models',
              'segments': <dynamic>[
                <String, dynamic>{
                  'lit': 'v1',
                },
                <String, dynamic>{
                  'lit': 'models',
                },
              ],
              'parts': <dynamic>[
                'v1',
                'models',
              ],
              'rename': <String, dynamic>{},
              'transform': <String, dynamic>{
                'req': '`reqdata`',
                'res': '`body.data`',
              },
              'args': <String, dynamic>{},
              'select': <String, dynamic>{},
              'live': <String, dynamic>{
                'assert': <String, dynamic>{
                  'nonempty': <dynamic>[
                    '',
                  ],
                },
                'auth': 'public',
                'id': 'models',
              },
              'response': <String, dynamic>{
                'kind': 'json',
                'media': 'application/json',
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
