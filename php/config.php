<?php
declare(strict_types=1);

// Univec SDK configuration

class UnivecConfig
{
    /** @var array<string,mixed>|null */
    private static ?array $shared_config = null;

    /**
     * Return the process-wide config, built once on first use. The SDK reads
     * the config on every request and never writes to it, so one instance is
     * shared by every client rather than rebuilt per client.
     *
     * PHP arrays are copy-on-write, so callers that do mutate the result get
     * their own copy and cannot disturb the shared one.
     */
    public static function shared_config(): array
    {
        if (self::$shared_config === null) {
            self::$shared_config = self::make_config();
        }
        return self::$shared_config;
    }

    /**
     * Build a fresh, fully materialised config array. Every call rebuilds the
     * whole structure, so prefer shared_config unless you need a private copy.
     */
    public static function make_config(): array
    {
        return [
            "main" => [
                "name" => "Univec",
                "slug" => "univec",
                "version" => "0.1.2",
                "target" => "php",
            ],
            "feature" => [
                "audit" => [
          'options' => [
            'active' => false,
            'actor' => 'anonymous',
            'max' => 1000,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "cache" => [
          'options' => [
            'active' => false,
            'max' => 256,
            'methods' => [
              'GET',
            ],
            'ttl' => 5000,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'wrap',
        ],
                "clienttrack" => [
          'options' => [
            'active' => false,
            'clientVersion' => '0.0.1',
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "cost" => [
          'options' => [
            'active' => false,
            'budget' => 0,
            'currency' => 'USD',
            'header' => '',
            'onBudget' => 'warn',
            'path' => '',
            'perUnit' => 0,
            'rates' => [],
            'unit' => 0,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'wrap',
        ],
                "debug" => [
          'options' => [
            'active' => false,
            'max' => 100,
            'redact' => [
              'authorization',
              'cookie',
              'set-cookie',
              'api-key',
              'apikey',
              'x-api-key',
              'idempotency-key',
            ],
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "idempotency" => [
          'options' => [
            'active' => false,
            'header' => 'Idempotency-Key',
            'methods' => [
              'POST',
              'PUT',
              'PATCH',
              'DELETE',
            ],
            'ops' => [
              'create',
              'update',
              'remove',
            ],
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "log" => [
          'options' => [
            'active' => true,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "metrics" => [
          'options' => [
            'active' => false,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "netsim" => [
          'options' => [
            'active' => false,
            'errorTimes' => 0,
            'failEvery' => 0,
            'failRate' => 0,
            'failStatus' => 503,
            'failTimes' => 0,
            'latency' => 0,
            'offline' => false,
            'rateLimitTimes' => 0,
            'retryAfter' => 0,
            'seed' => 1,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'wrap',
        ],
                "paging" => [
          'options' => [
            'active' => false,
            'afterVar' => 'after',
            'cursorParam' => 'cursor',
            'firstVar' => 'first',
            'limitParam' => 'limit',
            'pageParam' => 'page',
            'startPage' => 1,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "proxy" => [
          'options' => [
            'active' => false,
            'fromEnv' => false,
            'noProxy' => [],
            'url' => '',
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'wrap',
        ],
                "ratelimit" => [
          'options' => [
            'active' => false,
            'burst' => 5,
            'rate' => 5,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'wrap',
        ],
                "rbac" => [
          'options' => [
            'active' => false,
            'deny' => false,
            'permissions' => [],
            'rules' => [],
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "retry" => [
          'options' => [
            'active' => false,
            'factor' => 2,
            'maxDelay' => 2000,
            'minDelay' => 50,
            'retries' => 2,
            'statuses' => [
              408,
              425,
              429,
              500,
              502,
              503,
              504,
            ],
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'wrap',
        ],
                "secrets" => [
          'options' => [
            'active' => false,
            'cache' => true,
            'exchange' => [
              'active' => false,
              'method' => 'POST',
              'path' => 'auth/token',
              'refresh' => '',
              'request' => 'refresh_token',
              'response' => 'access_token',
              'retries' => 1,
              'statuses' => [
                401,
              ],
            ],
            'name' => 'univec',
            'providers' => [
              [
                'kind' => 'boru',
                'namespace' => 'sdk',
              ],
            ],
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'wrap',
        ],
                "streaming" => [
          'options' => [
            'active' => false,
            'chunkDelay' => 0,
            'chunkSize' => 0,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "telemetry" => [
          'options' => [
            'active' => false,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'none',
        ],
                "test" => [
          'options' => [
            'active' => false,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'base',
        ],
                "timeout" => [
          'options' => [
            'active' => false,
            'ms' => 30000,
          ],
          'optspec' => [],
          'strict' => false,
          'transport' => 'wrap',
        ],
            ],
            "options" => [
                "base" => "https://api.univec.ai",
                "auth" => [
                    "prefix" => "Bearer",
                ],
                "headers" => [
          'content-type' => 'application/json',
        ],
                "entity" => [
                    "convert" => [],
                    "embed" => [],
                    "ephemeral_key" => [],
                    "model" => [],
                ],
            ],
            "entity" => [
        'convert' => [
          'fields' => [
            [
              'name' => 'bridge_model',
              'req' => true,
              'short' => 'Embed model used to vectorise the text before translation.',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'embeddings',
              'req' => true,
              'short' => 'Translated vectors, in the target model\'s dimension.',
              'type' => '`$ARRAY`',
            ],
            [
              'name' => 'source_model',
              'req' => true,
              'short' => 'Model space the supplied vectors are currently in.',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'target_model',
              'req' => true,
              'short' => 'Model space to translate into.',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'texts',
              'req' => true,
              'short' => 'Texts to embed and translate.',
              'type' => '`$ARRAY`',
            ],
          ],
          'name' => 'convert',
          'op' => [
            'create' => [
              'input' => 'data',
              'name' => 'create',
              'points' => [
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/convert',
                  'segments' => [
                    [
                      'lit' => 'v1',
                    ],
                    [
                      'lit' => 'convert',
                    ],
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                  'parts' => [
                    'v1',
                    'convert',
                  ],
                ],
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/embed-bridge',
                  'segments' => [
                    [
                      'lit' => 'v1',
                    ],
                    [
                      'lit' => 'embed-bridge',
                    ],
                  ],
                  'select' => [
                    '$action' => 'bridge',
                  ],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                  'parts' => [
                    'v1',
                    'embed-bridge',
                  ],
                ],
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/ephemeral/convert',
                  'segments' => [
                    [
                      'lit' => 'v1',
                    ],
                    [
                      'lit' => 'ephemeral',
                    ],
                    [
                      'lit' => 'convert',
                    ],
                  ],
                  'select' => [
                    '$action' => 'ephemeral',
                  ],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                  'parts' => [
                    'v1',
                    'ephemeral',
                    'convert',
                  ],
                ],
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/ephemeral/embed-bridge',
                  'segments' => [
                    [
                      'lit' => 'v1',
                    ],
                    [
                      'lit' => 'ephemeral',
                    ],
                    [
                      'lit' => 'embed-bridge',
                    ],
                  ],
                  'select' => [
                    '$action' => 'ephemeral_bridge',
                  ],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                  'parts' => [
                    'v1',
                    'ephemeral',
                    'embed-bridge',
                  ],
                ],
              ],
            ],
          ],
          'relations' => [
            'ancestors' => [],
          ],
        ],
        'embed' => [
          'fields' => [
            [
              'name' => 'embeddings',
              'req' => true,
              'short' => 'One vector per input text, in input order.',
              'type' => '`$ARRAY`',
            ],
            [
              'name' => 'model',
              'req' => true,
              'short' => 'Model that produced the vectors.',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'texts',
              'req' => true,
              'short' => 'Texts to embed.',
              'type' => '`$ARRAY`',
            ],
          ],
          'name' => 'embed',
          'op' => [
            'create' => [
              'input' => 'data',
              'name' => 'create',
              'points' => [
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/embed',
                  'segments' => [
                    [
                      'lit' => 'v1',
                    ],
                    [
                      'lit' => 'embed',
                    ],
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                  'parts' => [
                    'v1',
                    'embed',
                  ],
                ],
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/ephemeral/embed',
                  'segments' => [
                    [
                      'lit' => 'v1',
                    ],
                    [
                      'lit' => 'ephemeral',
                    ],
                    [
                      'lit' => 'embed',
                    ],
                  ],
                  'select' => [
                    '$action' => 'ephemeral',
                  ],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                  'parts' => [
                    'v1',
                    'ephemeral',
                    'embed',
                  ],
                ],
              ],
            ],
          ],
          'relations' => [
            'ancestors' => [],
          ],
        ],
        'ephemeral_key' => [
          'fields' => [
            [
              'name' => 'dailyLimit',
              'req' => true,
              'short' => 'Calls permitted per day.',
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'dailyUsed',
              'req' => true,
              'short' => 'Calls already used today.',
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'key',
              'req' => true,
              'short' => 'The ephemeral API key, prefixed `eph_`.',
              'type' => '`$STRING`',
            ],
            [
              'format' => 'date-time',
              'name' => 'resetsAt',
              'req' => true,
              'short' => 'When the daily allowance resets.',
              'type' => '`$STRING`',
            ],
          ],
          'name' => 'ephemeral_key',
          'op' => [
            'create' => [
              'input' => 'data',
              'name' => 'create',
              'points' => [
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/ephemeral/key',
                  'segments' => [
                    [
                      'lit' => 'v1',
                    ],
                    [
                      'lit' => 'ephemeral',
                    ],
                    [
                      'lit' => 'key',
                    ],
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                  'parts' => [
                    'v1',
                    'ephemeral',
                    'key',
                  ],
                ],
              ],
            ],
          ],
          'relations' => [
            'ancestors' => [],
          ],
        ],
        'model' => [
          'fields' => [
            [
              'name' => 'eval',
              'short' => 'Retrieval-fidelity metrics for a convert model.',
              'type' => '`$OBJECT`',
            ],
            [
              'name' => 'executionProvider',
              'short' => 'Hardware backend, e.g.',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'modelCard',
              'short' => 'Convert models only: training provenance and architecture detail.',
              'type' => '`$OBJECT`',
            ],
            [
              'name' => 'modelType',
              'req' => true,
              'short' => '`embed` for text-to-vector models, `convert` for space-translation models.',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'name',
              'req' => true,
              'short' => 'Model identifier used in requests.',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'sequenceLen',
              'short' => 'Embed models only: maximum input sequence length.',
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'sourceDim',
              'short' => 'Convert models only: source vector dimension.',
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'sourceModel',
              'short' => 'Convert models only: the source model space.',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'targetDim',
              'req' => true,
              'short' => 'Dimension of the produced vectors.',
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'targetModel',
              'req' => true,
              'short' => 'The model space produced.',
              'type' => '`$STRING`',
            ],
          ],
          'name' => 'model',
          'op' => [
            'list' => [
              'input' => 'data',
              'name' => 'list',
              'points' => [
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'GET',
                  'orig' => '/v1/models',
                  'segments' => [
                    [
                      'lit' => 'v1',
                    ],
                    [
                      'lit' => 'models',
                    ],
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                  'parts' => [
                    'v1',
                    'models',
                  ],
                ],
              ],
            ],
          ],
          'relations' => [
            'ancestors' => [],
          ],
        ],
      ],
        ];
    }


    /**
     * The sekreto plugin DEFINITIONS the model selected per feature, from
     * the files the catalogue's active `plugin.def` entries declare.
     * Handed to each feature (secrets builds its Sekreto with them): a
     * provider kind not listed here is unknown to this SDK.
     *
     * A method rather than a constant: a definition holds closures, and PHP
     * has no constant that can. The requires are INSIDE it, so a plugin
     * file is read only when a feature asks for its definitions.
     */
    public static function feature_plugins(string $name): array
    {
        switch ($name) {
            case "secrets":
                require_once __DIR__ . '/feature/secrets/sekreto/plugins/boru.php';
                require_once __DIR__ . '/feature/secrets/sekreto/plugins/hashicorp.php';
                return [
                    \Voxgig\Sekreto\Plugins\boru(),
                    \Voxgig\Sekreto\Plugins\hashicorp(),
                ];
        }

        return [];
    }

    public static function make_feature(string $name)
    {
        require_once __DIR__ . '/features.php';
        return UnivecFeatures::make_feature($name);
    }
}
