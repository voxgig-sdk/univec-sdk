<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/gcpsecrets.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * GCP Secret Manager, as a voxgig/plugin definition.
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
 * GCP Secret Manager.
 *
 * `api.token` reads secret `api_token` (dots flattened to `_`; Secret
 * Manager ids have no hierarchy and reject dots), latest version. The
 * token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
 * GCE/GKE metadata server - so on Google's own platform no credential
 * configuration is needed at all.
 *
 * The metadata call itself is plain http to a link-local host by platform
 * design; no credential rides on it, so `checkaddr` guards the Secret
 * Manager address instead.
 */
class GcpSecretsProvider implements Provider
{
    // A configured token is kept forever; a metadata-server token carries
    // expires_in and is renewed shortly before it runs out.
    private ?string $livetoken = null;
    private float $renewat = INF;

    /** @param array<string, mixed> $opts */
    public function __construct(private array $opts = [])
    {
    }

    private function metadataaddr(): string
    {
        $addr = $this->opts['metadataaddr'] ?? null;
        if ($addr) {
            return $addr;
        }

        $host = getenv('GCE_METADATA_HOST');

        return $host ? 'http://' . $host : 'http://metadata.google.internal';
    }

    private function login(): string
    {
        $configured = ($this->opts['token'] ?? null) ?: getenv('GOOGLE_OAUTH_ACCESS_TOKEN');
        if ($configured) {
            return $configured;
        }

        $url = rtrim($this->metadataaddr(), '/')
            . '/computeMetadata/v1/instance/service-accounts/default/token';

        [$status, $body] = fetchjson('GET', $url, ['Metadata-Flavor: Google']);

        $got = $body['access_token'] ?? null;
        if (200 !== $status || !$got) {
            throw new SekretoError('sekreto: gcp: no token and metadata server did not answer');
        }

        $expires = (float) ($body['expires_in'] ?? 0);
        $this->renewat = 0 < $expires ? microtime(true) + max($expires - 60, 1) : INF;

        return (string) $got;
    }

    public function lookup(string $name): ?string
    {
        $project = $this->opts['project'] ?? '';
        if ('' === $project || null === $project) {
            throw new SekretoError('sekreto: gcp: no project');
        }

        $addr = ($this->opts['addr'] ?? null) ?: 'https://secretmanager.googleapis.com';
        checkaddr($addr);

        if (null === $this->livetoken || microtime(true) >= $this->renewat) {
            $this->livetoken = $this->login();
        }

        $url = rtrim($addr, '/') . '/v1/projects/' . $project . '/secrets/'
            . Name::flatname($name, '_') . '/versions/latest:access';

        [$status, $body] = fetchjson('GET', $url, ['Authorization: Bearer ' . $this->livetoken]);

        if (404 === $status) {
            return null;
        }

        if (200 !== $status) {
            throw new SekretoError('sekreto: gcp error: ' . $status . ': ' . $url);
        }

        $data = $body['payload']['data'] ?? null;
        if (!is_string($data)) {
            return null;
        }

        // See the aws provider: strict, and an undecodable payload is an
        // error rather than a miss.
        $decoded = base64_decode($data, true);
        if (false === $decoded) {
            throw new SekretoError('sekreto: gcp: undecodable secret');
        }

        return $decoded;
    }

    public function describe(): string
    {
        return 'gcpsecrets:' . ($this->opts['project'] ?? '');
    }
}

/**
 * The `gcpsecrets` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function gcpsecrets(): array
{
    return providerplugin('gcpsecrets', fn(array $spec) => new GcpSecretsProvider($spec));
}
