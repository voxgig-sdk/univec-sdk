<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/boru.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * The boru vault, as a voxgig/plugin definition.
 *
 * A PLUGIN, not a built-in: it spawns a child process, and over the wire it
 * opens a socket too.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto\Plugins;

require_once __DIR__ . '/../src/Providers.php';
require_once __DIR__ . '/../src/Addr.php';
require_once __DIR__ . '/httpjson.php';
require_once __DIR__ . '/runcmd.php';

use Voxgig\Sekreto\Name;
use Voxgig\Sekreto\Provider;
use Voxgig\Sekreto\SekretoError;

use function Voxgig\Sekreto\checkaddr;
use function Voxgig\Sekreto\providerplugin;

/**
 * A boru vault (https://github.com/boru-lang/boru).
 *
 * Two ways in, both boru's own.
 *
 * With no `addr`, the CLI: `boru vault get --reveal <alias>` prints the
 * secret on stdout and nothing else. The passphrase is read by boru itself
 * from `BORU_VAULT_PASSPHRASE`; sekreto never accepts it as config and
 * never puts it on a command line, where it would show up in the process
 * table.
 *
 * With an `addr`, boru's wire protocol: `boru vault serve` publishes a
 * read-only, HashiCorp-shaped provision API (boru's
 * design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
 * from `boru vault grant`. A sekreto name is already a valid boru alias,
 * and boru aliases keep their dots, so `api.token` is the single path
 * segment `api.token` - not the `api`/`token` split a HashiCorp KV gets.
 * The value is the `value` field. A 404 is a miss; anything else the
 * server refuses (a revoked capability, a sealed vault) is an error.
 *
 * boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
 * credential *broker*, built precisely so the caller never receives the
 * credential. `vault serve` is the provision endpoint, built to hand the
 * value back - that is the one sekreto uses.
 */
class BoruProvider implements Provider
{
    private string $command;
    private ?string $addr;

    public function __construct(
        ?string $command = null,
        private ?string $namespace = null,
        private ?string $home = null,
        ?string $addr = null,
        private ?string $token = null,
        private ?string $mount = null
    ) {
        $this->command = $command ?? 'boru';
        $this->addr = $addr ? preg_replace('#/$#', '', $addr) : null;
    }

    private function wirelookup(string $name): ?string
    {
        Name::check($name);
        checkaddr($this->addr);

        $alias = $this->namespace ? $this->namespace . '/' . $name : $name;
        $url = $this->addr . '/v1/' . ($this->mount ?: 'secret') . '/data/' . $alias;

        [$status, $body] = fetchjson('GET', $url, ['X-Vault-Token: ' . ($this->token ?? '')]);

        if (404 === $status) {
            return null;
        }

        if (200 !== $status) {
            throw new SekretoError('sekreto: boru serve error: ' . $status . ': ' . $url);
        }

        $data = $body['data']['data'] ?? null;
        $value = is_array($data) ? ($data['value'] ?? null) : null;

        return null === $value ? null : (string) $value;
    }

    public function lookup(string $name): ?string
    {
        if ($this->addr) {
            return $this->wirelookup($name);
        }

        Name::check($name);

        $alias = $this->namespace ? $this->namespace . ':' . $name : $name;

        [$out, $why, $status] = runcmd(
            [$this->command, 'vault', 'get', '--reveal', $alias],
            $this->home ? ['BORU_HOME' => $this->home] : []
        );

        if (0 === $status) {
            // boru prints the value and one newline, and nothing else.
            return preg_replace('/\n\z/', '', $out, 1);
        }

        // "no alias named" is boru saying it does not hold this secret, which
        // is a miss: the chain carries on to the next provider. A locked vault
        // or a wrong passphrase is not a miss - treating it as one would fall
        // through to a weaker store without saying so.
        if (borumiss($why)) {
            return null;
        }

        throw new SekretoError(
            'sekreto: boru vault error: ' . ('' === $why ? 'exit ' . $status : $why)
        );
    }

    public function describe(): string
    {
        if ($this->addr) {
            return 'boru:' . $this->addr;
        }

        return 'boru' . ($this->namespace ? ':' . $this->namespace : '');
    }
}

/**
 * Does this boru failure mean "no such secret" rather than "I could not
 * answer"? Matched on boru's own wording for a missing alias.
 */
function borumiss(string $why): bool
{
    return str_contains($why, 'no alias named');
}

/**
 * The `boru` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function boru(): array
{
    return providerplugin('boru', fn(array $spec) => new BoruProvider(
        $spec['command'] ?? null,
        $spec['namespace'] ?? null,
        $spec['home'] ?? null,
        $spec['addr'] ?? null,
        $spec['token'] ?? null,
        $spec['mount'] ?? null
    ));
}
