<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/hashicorp.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * HashiCorp Vault, as a voxgig/plugin definition.
 *
 * A PLUGIN, not a built-in: it opens a socket. The four built-in kinds read
 * at most a local file, and a chain of them never requires this file.
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
 * HashiCorp Vault.
 *
 * KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
 * takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
 * `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
 * here" - a miss - so a vault can sit in a chain with fallbacks.
 *
 * A Vault Enterprise namespace rides the X-Vault-Namespace header, on
 * logins as well as reads.
 *
 * Instead of being handed a token, the provider can log in: Kubernetes
 * auth (the pod's service-account JWT, from its conventional path) or
 * AppRole. A failed login is an error, never a miss - it means this store
 * could not answer at all.
 */
class HashicorpProvider implements Provider
{
    private string $mount;
    private int $kv;

    /**
     * The working token: a configured token is kept forever, a logged-in
     * token is renewed shortly before its lease runs out - a long-running
     * process must not keep presenting a token the vault already expired.
     */
    private ?string $livetoken;
    private float $renewat = INF;

    /** @param array<string, mixed>|null $auth */
    public function __construct(
        private string $addr,
        string $token,
        ?string $mount = null,
        ?int $kv = null,
        private ?string $vaultnamespace = null,
        private ?array $auth = null
    ) {
        $this->mount = $mount ?? 'secret';
        $this->kv = $kv ?: 2;

        // A version typo like kv: 3 must not quietly behave as v2 and turn
        // its 404s into misses; there is nothing safe to assume it meant.
        if (1 !== $this->kv && 2 !== $this->kv) {
            throw new SekretoError(
                'sekreto: hashicorp: unsupported kv version: ' . $this->kv
            );
        }

        $this->livetoken = '' === $token ? null : $token;
    }

    /** @return array<int, string> */
    private function baseheaders(): array
    {
        $headers = [];

        if ($this->vaultnamespace) {
            $headers[] = 'X-Vault-Namespace: ' . $this->vaultnamespace;
        }

        return $headers;
    }

    private function login(): string
    {
        $auth = $this->auth;

        if (null === $auth) {
            throw new SekretoError('sekreto: hashicorp: no token and no auth method');
        }

        $method = $auth['method'] ?? null;
        $mount = $auth['mount'] ?? $method;
        $url = rtrim($this->addr, '/') . '/v1/auth/' . $mount . '/login';

        if ('kubernetes' === $method) {
            $jwt = $auth['jwt'] ?? null;
            if (null === $jwt) {
                $file = ($auth['jwtfile'] ?? null)
                    ?: '/var/run/secrets/kubernetes.io/serviceaccount/token';
                $text = @file_get_contents($file);
                if (false === $text) {
                    throw new SekretoError('sekreto: hashicorp: cannot read jwt file ' . $file);
                }
                $jwt = trim($text);
            }
            $body = ['role' => $auth['role'] ?? '', 'jwt' => $jwt];
        } elseif ('approle' === $method) {
            $body = [
                'role_id' => $auth['roleid'] ?? '',
                'secret_id' => $auth['secretid'] ?? '',
            ];
        } else {
            throw new SekretoError(
                'sekreto: hashicorp: unknown auth method: ' . (string) $method
            );
        }

        [$status, $answer] = fetchjson('POST', $url, $this->baseheaders(), writejson($body));

        $got = $answer['auth']['client_token'] ?? null;
        if (200 !== $status || !$got) {
            throw new SekretoError('sekreto: hashicorp login failed: ' . $status . ': ' . $url);
        }

        $lease = (float) ($answer['auth']['lease_duration'] ?? 0);
        $this->renewat = 0 < $lease ? microtime(true) + max($lease - 60, 1) : INF;

        return (string) $got;
    }

    public function lookup(string $name): ?string
    {
        checkaddr($this->addr);

        if (null === $this->livetoken || microtime(true) >= $this->renewat) {
            $this->livetoken = $this->login();
        }

        $ref = Name::vaultref($name);
        $base = rtrim($this->addr, '/') . '/v1/' . $this->mount;
        $url = 1 === $this->kv ? $base . '/' . $ref['path'] : $base . '/data/' . $ref['path'];

        $headers = $this->baseheaders();
        $headers[] = 'X-Vault-Token: ' . $this->livetoken;

        [$status, $body] = fetchjson('GET', $url, $headers);

        if (404 === $status) {
            return null;
        }

        if (200 !== $status) {
            throw new SekretoError('sekreto: hashicorp error: ' . $status . ': ' . $url);
        }

        $data = 1 === $this->kv ? ($body['data'] ?? null) : ($body['data']['data'] ?? null);
        $value = is_array($data) ? ($data[$ref['field']] ?? null) : null;

        return null === $value ? null : (string) $value;
    }

    public function describe(): string
    {
        return 'hashicorp:' . $this->addr . '/' . $this->mount;
    }
}

/**
 * The `hashicorp` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function hashicorp(): array
{
    return providerplugin('hashicorp', fn(array $spec) => new HashicorpProvider(
        $spec['addr'] ?? '',
        $spec['token'] ?? '',
        $spec['mount'] ?? null,
        isset($spec['kv']) ? (int) $spec['kv'] : null,
        $spec['vaultnamespace'] ?? null,
        $spec['auth'] ?? null
    ));
}
