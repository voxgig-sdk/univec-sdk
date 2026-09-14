<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/secretspec.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * SecretSpec, as a voxgig/plugin definition.
 *
 * A PLUGIN, not a built-in: it spawns a child process.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto\Plugins;

require_once __DIR__ . '/../src/Providers.php';
require_once __DIR__ . '/runcmd.php';

use Voxgig\Sekreto\Name;
use Voxgig\Sekreto\Provider;
use Voxgig\Sekreto\SekretoError;

use function Voxgig\Sekreto\providerplugin;

/**
 * SecretSpec (https://secretspec.dev).
 *
 * SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
 * project needs - plus a chain of its own backends to satisfy them from.
 * That makes it the same shape as sekreto one level down, and the reason
 * to support it is the same reason sekreto exists: a project that has
 * already declared its secrets there should not have to declare them
 * again here.
 *
 * Read through its CLI, as boru is, because that is the interface it
 * offers a program in another language: `secretspec get API_TOKEN` prints
 * the value on stdout and nothing else. A sekreto name maps to a
 * SecretSpec key exactly as it maps to an environment variable -
 * `api.token` is `API_TOKEN` - which is the convention SecretSpec's own
 * examples use.
 *
 * `backend` selects one of SecretSpec's backends (`--provider`, e.g.
 * `keyring` or `dotenv://.env`) and is called `backend` here only because
 * `provider` already means something else in this library.
 *
 * A reason is required, not optional: SecretSpec records every read in an
 * audit log and refuses to read at all without one. sekreto sends
 * `sekreto` unless told otherwise, so the audit trail says which tool
 * asked.
 */
class SecretspecProvider implements Provider
{
    private string $command;

    public function __construct(
        ?string $command = null,
        private ?string $file = null,
        private ?string $profile = null,
        private ?string $backend = null,
        private ?string $reason = null,
        private ?string $prefix = null
    ) {
        $this->command = $command ?? 'secretspec';
    }

    public function lookup(string $name): ?string
    {
        $key = Name::envkey($name, $this->prefix);

        $argv = [$this->command];
        if ($this->file) {
            $argv[] = '--file';
            $argv[] = $this->file;
        }
        $argv[] = 'get';
        $argv[] = $key;
        if ($this->backend) {
            $argv[] = '--provider';
            $argv[] = $this->backend;
        }
        if ($this->profile) {
            $argv[] = '--profile';
            $argv[] = $this->profile;
        }
        $argv[] = '--reason';
        $argv[] = $this->reason ?: 'sekreto';

        [$out, $why, $status] = runcmd($argv);

        if (0 === $status) {
            // The value and one newline, and nothing else.
            return preg_replace('/\n\z/', '', $out, 1);
        }

        if (secretspecmiss($why, $key)) {
            return null;
        }

        throw new SekretoError(
            'sekreto: secretspec error: ' . ('' === $why ? 'exit ' . $status : $why)
        );
    }

    public function describe(): string
    {
        return 'secretspec' . ($this->backend ? ':' . $this->backend : '');
    }
}

/**
 * Does this SecretSpec failure mean "no such secret" rather than "I could
 * not answer"?
 *
 * SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does
 * not declare and one declared with no value, and both are misses: this
 * store does not hold it, so the chain carries on.
 *
 * MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
 * `Provider backend 'keyring' not found`, which is a store that could not
 * answer at all - and reading that as a miss is the worst failure this
 * library has, because the chain then falls through to a weaker store
 * without saying so. The key is required to appear, so the two cannot be
 * confused.
 */
function secretspecmiss(string $why, string $key): bool
{
    return str_contains($why, "Secret '" . $key . "' not found");
}

/**
 * The `secretspec` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function secretspec(): array
{
    return providerplugin('secretspec', fn(array $spec) => new SecretspecProvider(
        $spec['command'] ?? null,
        $spec['file'] ?? null,
        $spec['profile'] ?? null,
        $spec['backend'] ?? null,
        $spec['reason'] ?? null,
        $spec['prefix'] ?? null
    ));
}
