<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/src/Providers.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * What a provider is, how a provider kind becomes a voxgig/plugin
 * definition - and the four BUILT-IN kinds.
 *
 * A provider answers one question: "do you have this secret?" It returns
 * the value, or null to mean "ask the next one". Nothing else about a
 * provider is visible to the caller - which is the point: an app reads
 * `api.token` and never learns whether it came from the environment, a
 * .env file, HashiCorp Vault or a boru vault.
 *
 * Two failure shapes, and they are never interchangeable. A store that
 * does not hold the secret is a MISS (null) - the chain carries on. A
 * store that could not answer - bad credentials, unreachable host,
 * missing configuration - is an ERROR: falling through there would
 * quietly reach for a weaker store.
 *
 * THIS FILE REQUIRES NOTHING UNDER plugins/, OPENS NO SOCKET, SPAWNS NO
 * PROCESS AND HASHES NOTHING. What makes a kind built in is that it needs
 * nothing of the platform beyond reading a local file; every kind that
 * opens a socket, signs a request or spawns a process is a plugin under
 * plugins/, in its own file and its own namespace, required only by a
 * program that names it (docs/design/plugin-providers.md).
 *
 * A port of typescript/src/provider/support.ts and
 * typescript/src/provider/builtin.ts, which are canonical.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto;

require_once __DIR__ . '/Sekreto.php';

use Voxgig\Plugin\Inst;
use Voxgig\Plugin\PluginError;

/** A source of secrets. `lookup` returns the value or null. */
interface Provider
{
    public function lookup(string $name): ?string;

    public function describe(): string;
}

/** Environment variables: `api.token` from `API_TOKEN`. */
class EnvProvider implements Provider
{
    /** @param array<string, string>|null $source */
    public function __construct(private ?string $prefix = null, private ?array $source = null)
    {
    }

    public function lookup(string $name): ?string
    {
        $key = Name::envkey($name, $this->prefix);

        if (null !== $this->source) {
            return $this->source[$key] ?? null;
        }

        $value = getenv($key);

        return false === $value ? null : $value;
    }

    public function describe(): string
    {
        return 'env' . ($this->prefix ? ':' . $this->prefix : '');
    }
}

/** A `.env` file, read once, keyed exactly like the environment. */
class DotenvProvider implements Provider
{
    /** @var array<string, string>|null */
    private ?array $values = null;

    public function __construct(private string $file, private ?string $prefix = null)
    {
    }

    /** @return array<string, string> */
    private function load(): array
    {
        if (null === $this->values) {
            // Attempt the read outright rather than pre-checking with
            // file_exists(): that also reports false when a parent directory
            // is unreadable for permission reasons, which is a store that
            // could not answer, not a store without the secret.
            error_clear_last();
            $text = @file_get_contents($this->file);
            $raised = error_get_last();

            if (false === $text || null !== $raised) {
                $why = $raised['message'] ?? 'unknown error';

                // PHP's warning text carries the OS reason after its
                // "Failed to open stream:" preamble; keep just the reason.
                if (1 === preg_match('/Failed to open stream: (.*)$/s', $why, $match)) {
                    $why = $match[1];
                }

                // An absent file - or an absent directory - means "no secrets
                // here", exactly like FileProvider. Anything else (permission
                // denied, an unreadable mount) is a store that could not
                // answer, and swallowing it would fall through to a weaker
                // store.
                if (!str_contains($why, 'No such file or directory')
                    && !str_contains($why, 'Not a directory')
                ) {
                    throw new SekretoError(
                        'sekreto: dotenv provider cannot read ' . $this->file . ': ' . $why
                    );
                }

                $this->values = [];
            } else {
                $this->values = parsedotenv($text);
            }
        }

        return $this->values;
    }

    public function lookup(string $name): ?string
    {
        return $this->load()[Name::envkey($name, $this->prefix)] ?? null;
    }

    public function describe(): string
    {
        return 'dotenv:' . $this->file;
    }
}

/**
 * Literal values, keyed like environment variables. The spec uses this to
 * test chain behaviour without touching the outside world.
 */
class MemoryProvider implements Provider
{
    /** @param array<string, string> $values */
    public function __construct(private array $values, private ?string $prefix = null)
    {
    }

    public function lookup(string $name): ?string
    {
        $value = $this->values[Name::envkey($name, $this->prefix)] ?? null;

        return null === $value ? null : (string) $value;
    }

    public function describe(): string
    {
        return 'memory' . ($this->prefix ? ':' . $this->prefix : '');
    }
}

/**
 * A directory of one-secret-per-file entries, keyed like the environment:
 * `api.token` reads `<dir>/API_TOKEN`.
 *
 * This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
 * secret, and a systemd credentials directory, so those all work with no
 * further configuration. One trailing newline is stripped - tools that
 * write these files disagree about it, and a newline is never part of a
 * secret on purpose.
 */
class FileProvider implements Provider
{
    public function __construct(private string $dir, private ?string $prefix = null)
    {
    }

    public function lookup(string $name): ?string
    {
        $file = $this->dir . '/' . Name::envkey($name, $this->prefix);

        // Attempt the read outright rather than pre-checking with
        // file_exists(): that also reports false when a parent directory
        // is unreadable for permission reasons, which is a store that
        // could not answer, not a store without the secret. Any raised
        // error counts as a failed read, not only a false return - PHP
        // reports reading a directory as '' plus a notice.
        error_clear_last();
        $text = @file_get_contents($file);
        $raised = error_get_last();

        if (false === $text || null !== $raised) {
            $why = $raised['message'] ?? 'unknown error';

            // PHP's warning text carries the OS reason after its
            // "Failed to open stream:" preamble; keep just the reason.
            if (1 === preg_match('/Failed to open stream: (.*)$/s', $why, $match)) {
                $why = $match[1];
            }

            // An absent file - or an absent directory - means "no secrets
            // here", exactly like a missing .env. Anything else (permission
            // denied, an unreadable mount) is a store that could not answer.
            if (str_contains($why, 'No such file or directory')
                || str_contains($why, 'Not a directory')
            ) {
                return null;
            }

            throw new SekretoError(
                'sekreto: file provider cannot read ' . $file . ': ' . $why
            );
        }

        return preg_replace('/\r?\n\z/', '', $text, 1);
    }

    public function describe(): string
    {
        return 'file:' . $this->dir;
    }
}

// --- providers as voxgig/plugin definitions -------------------------------

/**
 * The export key under which a provider definition publishes the provider
 * it built. `Sekreto` reads `<ref>/provider` off the host.
 */
const PROVIDER_EXPORT = 'provider';

/**
 * The voxgig/plugin error code a SekretoError travels under when it is
 * thrown inside a definition's `define`.
 *
 * plugin wraps a code-less error thrown by a callback as
 * `plugin_define_failed`, and keeps an error that already carries a code.
 * A provider that refuses its own configuration - `kv: 3`, a missing
 * project - throws a SekretoError, and that message is pinned by the spec
 * byte for byte, so it must come back out of the host exactly as it went
 * in. `providerplugin` gives it this code on the way in; `Sekreto` turns
 * it back into a SekretoError on the way out.
 */
const ERROR_CODE = 'sekreto_error';

/**
 * A provider kind, as a voxgig/plugin definition.
 *
 * This is the whole bridge between the two libraries. The definition's
 * `name` is the `kind` a spec names; its `define` reads the spec as the
 * instance's options, builds the provider with `$make`, and exports it.
 * Nothing runs at `activate`: a provider opens nothing until its first
 * lookup, so there is nothing to capture - a provider that does hold a
 * resource acquires it there and lets the instance scope unwind it.
 *
 * Every built-in and every plugin is made this way, so a custom provider
 * kind is one call:
 *
 *     providerplugin('mystore', fn(array $spec) => new MyStore($spec['addr'] ?? null))
 *
 * @param callable(array<string, mixed>): Provider $make
 * @return array<string, mixed>
 */
function providerplugin(string $kind, callable $make): array
{
    return [
        'name' => $kind,
        'define' => function (Inst $inst) use ($make): void {
            try {
                $provider = $make($inst->options());
            } catch (SekretoError $err) {
                throw new PluginError(ERROR_CODE, $err->getMessage(),
                                      ['ref' => $inst->ref, 'cause' => $err->getMessage()]);
            }

            $inst->export(PROVIDER_EXPORT, $provider);
        },
    ];
}

/**
 * The four built-in provider kinds - the same four in every port. What
 * makes a kind built in is that it needs nothing of the platform beyond
 * reading a local file: no socket, no TLS, no crypto, no child process.
 *
 * A function rather than a constant because a definition holds closures,
 * and PHP has no constant that can.
 *
 * @return array<int, array<string, mixed>>
 */
function builtins(): array
{
    return [
        providerplugin('env', fn(array $spec) => new EnvProvider($spec['prefix'] ?? null)),
        providerplugin('memory', fn(array $spec) => new MemoryProvider(
            $spec['values'] ?? [],
            $spec['prefix'] ?? null
        )),
        providerplugin('dotenv', fn(array $spec) => new DotenvProvider(
            $spec['file'] ?? '.env',
            $spec['prefix'] ?? null
        )),
        providerplugin('file', fn(array $spec) => new FileProvider(
            $spec['dir'] ?? '',
            $spec['prefix'] ?? null
        )),
    ];
}

/**
 * Every kind this library ships, built in or as a plugin, so that an
 * unknown kind can be told from a plugin that was not passed in.
 */
const BUILTIN_KINDS = ['env', 'memory', 'dotenv', 'file'];

const PLUGIN_KINDS = [
    'hashicorp', 'boru', 'awssecrets', 'awsparams', 'gcpsecrets',
    'azuresecrets', 'onepassword', 'doppler', 'infisical', 'secretspec',
];
