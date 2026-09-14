<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/onepassword.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * 1Password Connect, as a voxgig/plugin definition.
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
 * 1Password, through a Connect server.
 *
 * The item titled `api.token` (titles keep their dots), in the named
 * vault. The value is the field with purpose PASSWORD, or the field
 * labelled `value`. A vault that cannot be found is an error - config
 * names it, so its absence is a broken store, not a missing secret.
 */
class OnePasswordProvider implements Provider
{
    private ?string $vaultid = null;

    /** @param array<string, mixed> $opts */
    public function __construct(private array $opts = [])
    {
    }

    /** @return array<int, string> */
    private function auth(): array
    {
        return ['Authorization: Bearer ' . ($this->opts['token'] ?? '')];
    }

    private function resolvevault(string $addr): string
    {
        $want = $this->opts['vault'] ?? '';
        if ('' === $want || null === $want) {
            throw new SekretoError('sekreto: onepassword: no vault');
        }

        [$status, $body] = fetchjson('GET', $addr . '/v1/vaults', $this->auth());

        if (200 !== $status || !is_array($body)) {
            throw new SekretoError('sekreto: onepassword error: ' . $status . ': listing vaults');
        }

        foreach ($body as $entry) {
            if (is_array($entry)
                && ($want === ($entry['id'] ?? null) || $want === ($entry['name'] ?? null))
            ) {
                return (string) $entry['id'];
            }
        }

        throw new SekretoError('sekreto: onepassword: no vault named ' . $want);
    }

    public function lookup(string $name): ?string
    {
        Name::check($name);

        $addr = rtrim($this->opts['addr'] ?? '', '/');
        if ('' === $addr) {
            throw new SekretoError('sekreto: onepassword: no addr');
        }
        checkaddr($addr);

        if (null === $this->vaultid) {
            $this->vaultid = $this->resolvevault($addr);
        }

        $filter = rawurlencode('title eq "' . $name . '"');
        [$status, $found] = fetchjson(
            'GET',
            $addr . '/v1/vaults/' . $this->vaultid . '/items?filter=' . $filter,
            $this->auth()
        );

        if (200 !== $status || !is_array($found)) {
            throw new SekretoError(
                'sekreto: onepassword error: ' . $status . ': finding ' . $name
            );
        }

        if (0 === count($found)) {
            return null;
        }

        [$status, $item] = fetchjson(
            'GET',
            $addr . '/v1/vaults/' . $this->vaultid . '/items/' . $found[0]['id'],
            $this->auth()
        );

        if (200 !== $status) {
            throw new SekretoError(
                'sekreto: onepassword error: ' . $status . ': reading ' . $name
            );
        }

        $fields = $item['fields'] ?? [];

        foreach ($fields as $field) {
            if (is_array($field) && 'PASSWORD' === ($field['purpose'] ?? null)) {
                $value = $field['value'] ?? null;
                return null === $value ? null : (string) $value;
            }
        }
        foreach ($fields as $field) {
            if (is_array($field) && 'value' === ($field['label'] ?? null)) {
                $value = $field['value'] ?? null;
                return null === $value ? null : (string) $value;
            }
        }

        return null;
    }

    public function describe(): string
    {
        return 'onepassword:' . ($this->opts['vault'] ?? '');
    }
}

/**
 * The `onepassword` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function onepassword(): array
{
    return providerplugin('onepassword', fn(array $spec) => new OnePasswordProvider($spec));
}
