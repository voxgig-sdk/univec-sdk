<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/infisical.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Infisical, as a voxgig/plugin definition.
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
use function Voxgig\Sekreto\writejson;

/**
 * Infisical.
 *
 * `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
 * convention is environment-style keys) at a secret path in one
 * environment of a project. Auth is a token, or a universal-auth (machine
 * identity) login with clientid/clientsecret.
 */
class InfisicalProvider implements Provider
{
    // A configured token is kept forever; a universal-auth token carries
    // expiresIn and is renewed shortly before it runs out.
    private ?string $livetoken = null;
    private float $renewat = INF;

    /** @param array<string, mixed> $opts */
    public function __construct(private array $opts = [])
    {
    }

    private function login(string $addr): string
    {
        if ($this->opts['token'] ?? null) {
            return $this->opts['token'];
        }

        $clientid = $this->opts['clientid'] ?? null;
        $clientsecret = $this->opts['clientsecret'] ?? null;
        if (!$clientid || !$clientsecret) {
            throw new SekretoError('sekreto: infisical: no token and no client credentials');
        }

        [$status, $body] = fetchjson(
            'POST',
            $addr . '/api/v1/auth/universal-auth/login',
            ['Content-Type: application/json'],
            writejson(['clientId' => $clientid, 'clientSecret' => $clientsecret])
        );

        $got = $body['accessToken'] ?? null;
        if (200 !== $status || !$got) {
            throw new SekretoError('sekreto: infisical login failed: ' . $status);
        }

        $expires = (float) ($body['expiresIn'] ?? 0);
        $this->renewat = 0 < $expires ? microtime(true) + max($expires - 60, 1) : INF;

        return (string) $got;
    }

    public function lookup(string $name): ?string
    {
        $addr = rtrim(($this->opts['addr'] ?? null) ?: 'https://app.infisical.com', '/');
        checkaddr($addr);

        $project = $this->opts['project'] ?? '';
        $environment = $this->opts['environment'] ?? '';
        if ('' === $project || null === $project
            || '' === $environment || null === $environment
        ) {
            throw new SekretoError('sekreto: infisical: no project/environment');
        }

        if (null === $this->livetoken || microtime(true) >= $this->renewat) {
            $this->livetoken = $this->login($addr);
        }

        $url = $addr . '/api/v3/secrets/raw/' . Name::envkey($name)
            . '?workspaceId=' . rawurlencode($project)
            . '&environment=' . rawurlencode($environment)
            . '&secretPath=' . rawurlencode(($this->opts['path'] ?? null) ?: '/');

        [$status, $body] = fetchjson('GET', $url, ['Authorization: Bearer ' . $this->livetoken]);

        if (404 === $status) {
            return null;
        }

        if (200 !== $status) {
            throw new SekretoError('sekreto: infisical error: ' . $status);
        }

        $value = $body['secret']['secretValue'] ?? null;

        return null === $value ? null : (string) $value;
    }

    public function describe(): string
    {
        return 'infisical:' . ($this->opts['project'] ?? '')
            . '/' . ($this->opts['environment'] ?? '');
    }
}

/**
 * The `infisical` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function infisical(): array
{
    return providerplugin('infisical', fn(array $spec) => new InfisicalProvider($spec));
}
