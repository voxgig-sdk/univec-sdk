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
            ],
            "feature" => [
                "test" => [
          'options' => [
            'active' => false,
          ],
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
              'type' => '`$STRING`',
            ],
            [
              'name' => 'embeddings',
              'req' => true,
              'type' => '`$ARRAY`',
            ],
            [
              'name' => 'source_model',
              'req' => true,
              'type' => '`$STRING`',
            ],
            [
              'name' => 'target_model',
              'req' => true,
              'type' => '`$STRING`',
            ],
            [
              'name' => 'texts',
              'req' => true,
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
                  'parts' => [
                    'v1',
                    'convert',
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                ],
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/embed-bridge',
                  'parts' => [
                    'v1',
                    'embed-bridge',
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                ],
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/ephemeral/convert',
                  'parts' => [
                    'v1',
                    'ephemeral',
                    'convert',
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                ],
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/ephemeral/embed-bridge',
                  'parts' => [
                    'v1',
                    'ephemeral',
                    'embed-bridge',
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
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
              'type' => '`$ARRAY`',
            ],
            [
              'name' => 'model',
              'req' => true,
              'type' => '`$STRING`',
            ],
            [
              'name' => 'texts',
              'req' => true,
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
                  'parts' => [
                    'v1',
                    'embed',
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
                  ],
                ],
                [
                  'args' => [],
                  'kind' => 'http',
                  'method' => 'POST',
                  'orig' => '/v1/ephemeral/embed',
                  'parts' => [
                    'v1',
                    'ephemeral',
                    'embed',
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
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
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'dailyUsed',
              'req' => true,
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'key',
              'req' => true,
              'type' => '`$STRING`',
            ],
            [
              'name' => 'resetsAt',
              'req' => true,
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
                  'parts' => [
                    'v1',
                    'ephemeral',
                    'key',
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
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
              'type' => '`$OBJECT`',
            ],
            [
              'name' => 'executionProvider',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'modelCard',
              'type' => '`$OBJECT`',
            ],
            [
              'name' => 'modelType',
              'req' => true,
              'type' => '`$STRING`',
            ],
            [
              'name' => 'name',
              'req' => true,
              'type' => '`$STRING`',
            ],
            [
              'name' => 'sequenceLen',
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'sourceDim',
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'sourceModel',
              'type' => '`$STRING`',
            ],
            [
              'name' => 'targetDim',
              'req' => true,
              'type' => '`$INTEGER`',
            ],
            [
              'name' => 'targetModel',
              'req' => true,
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
                  'parts' => [
                    'v1',
                    'models',
                  ],
                  'select' => [],
                  'transform' => [
                    'req' => '`reqdata`',
                    'res' => '`body.data`',
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


    public static function make_feature(string $name)
    {
        require_once __DIR__ . '/features.php';
        return UnivecFeatures::make_feature($name);
    }
}
