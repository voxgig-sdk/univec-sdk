<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/azuresecrets.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * Azure Key Vault, as a voxgig/plugin definition.
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
 * Azure Key Vault.
 *
 * `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
 * names allow nothing else), current version. The token comes from
 * config, then a client-credentials login when tenant/clientid/
 * clientsecret are given, then the IMDS managed-identity endpoint - so on
 * Azure's own platform no credential configuration is needed.
 *
 * As with GCP, the IMDS call is plain http to a link-local host by
 * platform design and carries no credential; the login and vault
 * addresses are `checkaddr`-guarded.
 */
class AzureSecretsProvider implements Provider
{
    private const RESOURCE = 'https://vault.azure.net';

    // A configured token is kept forever; logged-in and IMDS tokens carry
    // expires_in and are renewed shortly before they run out.
    private ?string $livetoken = null;
    private float $renewat = INF;

    /** @param array<string, mixed> $opts */
    public function __construct(private array $opts = [])
    {
    }

    /** The renewal moment for an expires_in (which may be a string). */
    private function expiry(mixed $expires): float
    {
        $seconds = (float) $expires;

        return 0 < $seconds ? microtime(true) + max($seconds - 60, 1) : INF;
    }

    private function login(): string
    {
        $opts = $this->opts;

        if ($opts['token'] ?? null) {
            return $opts['token'];
        }

        if (($opts['tenant'] ?? null) && ($opts['clientid'] ?? null)
            && ($opts['clientsecret'] ?? null)
        ) {
            $loginaddr = ($opts['loginaddr'] ?? null) ?: 'https://login.microsoftonline.com';
            checkaddr($loginaddr);

            $url = rtrim($loginaddr, '/') . '/' . $opts['tenant'] . '/oauth2/v2.0/token';
            $form = 'grant_type=client_credentials'
                . '&client_id=' . rawurlencode($opts['clientid'])
                . '&client_secret=' . rawurlencode($opts['clientsecret'])
                . '&scope=' . rawurlencode(self::RESOURCE . '/.default');

            [$status, $body] = fetchjson(
                'POST',
                $url,
                ['Content-Type: application/x-www-form-urlencoded'],
                $form
            );

            $got = $body['access_token'] ?? null;
            if (200 !== $status || !$got) {
                throw new SekretoError('sekreto: azure login failed: ' . $status);
            }

            $this->renewat = $this->expiry($body['expires_in'] ?? null);

            return (string) $got;
        }

        $imds = rtrim(($opts['imdsaddr'] ?? null) ?: 'http://169.254.169.254', '/')
            . '/metadata/identity/oauth2/token?api-version=2018-02-01&resource='
            . rawurlencode(self::RESOURCE);

        [$status, $body] = fetchjson('GET', $imds, ['Metadata: true']);

        $got = $body['access_token'] ?? null;
        if (200 !== $status || !$got) {
            throw new SekretoError(
                'sekreto: azure: no token, no client credentials, and IMDS did not answer'
            );
        }

        $this->renewat = $this->expiry($body['expires_in'] ?? null);

        return (string) $got;
    }

    public function lookup(string $name): ?string
    {
        $vault = $this->opts['vault'] ?? '';
        if ('' === $vault || null === $vault) {
            throw new SekretoError('sekreto: azure: no vault');
        }

        // Only an explicit scheme is a URL; a vault NAMED httpvault must
        // still become https://httpvault.vault.azure.net.
        $vaulturl = str_starts_with($vault, 'http://') || str_starts_with($vault, 'https://')
            ? $vault
            : 'https://' . $vault . '.vault.azure.net';
        checkaddr($vaulturl);

        if (null === $this->livetoken || microtime(true) >= $this->renewat) {
            $this->livetoken = $this->login();
        }

        $url = rtrim($vaulturl, '/') . '/secrets/' . Name::flatname($name, '-')
            . '?api-version=' . (($this->opts['apiversion'] ?? null) ?: '7.4');

        [$status, $body] = fetchjson('GET', $url, ['Authorization: Bearer ' . $this->livetoken]);

        if (404 === $status) {
            return null;
        }

        if (200 !== $status) {
            throw new SekretoError(
                'sekreto: azure error: ' . $status . ': ' . explode('?', $url)[0]
            );
        }

        $value = $body['value'] ?? null;

        return null === $value ? null : (string) $value;
    }

    public function describe(): string
    {
        return 'azuresecrets:' . ($this->opts['vault'] ?? '');
    }
}

/**
 * The `azuresecrets` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function azuresecrets(): array
{
    return providerplugin('azuresecrets', fn(array $spec) => new AzureSecretsProvider($spec));
}
