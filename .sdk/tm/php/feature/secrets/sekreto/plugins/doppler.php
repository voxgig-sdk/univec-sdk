<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/doppler.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Doppler, as a voxgig/plugin definition.
 *
 * A PLUGIN, not a built-in: it opens a socket.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto\Plugins;

require_once __DIR__ . '/../src/Providers.php';
require_once __DIR__ . '/../src/Addr.php';
require_once __DIR__ . '/httpjson.php';

use Voxgig\Sekreto\Name;
use Voxgig\Sekreto\Provider;
use Voxgig\Sekreto\SekretoError;

use function Voxgig\Sekreto\checkaddr;
use function Voxgig\Sekreto\providerplugin;

/**
 * Doppler.
 *
 * The whole config is downloaded once - Doppler's own bulk endpoint - and
 * answered from memory, like a remote .env: `api.token` is the
 * `API_TOKEN` entry. A service token is config-scoped, so project and
 * config are only needed with broader tokens.
 */
class DopplerProvider implements Provider
{
    /** @var array<string, string>|null */
    private ?array $values = null;

    /** @param array<string, mixed> $opts */
    public function __construct(private array $opts = [])
    {
    }

    /** @return array<string, string> */
    private function load(): array
    {
        if (null !== $this->values) {
            return $this->values;
        }

        $addr = rtrim(($this->opts['addr'] ?? null) ?: 'https://api.doppler.com', '/');
        checkaddr($addr);

        $url = $addr . '/v3/configs/config/secrets/download?format=json';
        if ($this->opts['project'] ?? null) {
            $url .= '&project=' . rawurlencode($this->opts['project']);
        }
        if ($this->opts['config'] ?? null) {
            $url .= '&config=' . rawurlencode($this->opts['config']);
        }

        [$status, $body] = fetchjson(
            'GET',
            $url,
            ['Authorization: Bearer ' . ($this->opts['token'] ?? '')]
        );

        if (200 !== $status || !is_array($body)) {
            throw new SekretoError('sekreto: doppler error: ' . $status);
        }

        $this->values = [];
        foreach ($body as $key => $value) {
            if (null !== $value) {
                $this->values[$key] = (string) $value;
            }
        }

        return $this->values;
    }

    public function lookup(string $name): ?string
    {
        return $this->load()[Name::envkey($name)] ?? null;
    }

    public function describe(): string
    {
        $project = $this->opts['project'] ?? null;

        return 'doppler'
            . ($project ? ':' . $project . '/' . ($this->opts['config'] ?? '') : '');
    }
}

/**
 * The `doppler` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function doppler(): array
{
    return providerplugin('doppler', fn(array $spec) => new DopplerProvider($spec));
}
