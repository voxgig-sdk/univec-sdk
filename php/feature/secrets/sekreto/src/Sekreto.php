<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/src/Sekreto.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * sekreto: one interface for secrets, wherever they live.
 *
 * A Sekreto is an ordered chain of providers. `get` asks each in turn and
 * returns the first hit, so an app can be configured from environment
 * variables in development and a vault in production without changing a
 * line of its own code.
 *
 * A port of typescript/src/Sekreto.ts, which is canonical.
 *
 * THE CORE REQUIRES NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR
 * SIGNS A REQUEST. The four built-in kinds - env, memory, dotenv, file -
 * read at most a local file; every other kind is a voxgig/plugin
 * definition in its own file under plugins/ and its own namespace
 * (`Voxgig\Sekreto\Plugins`), and a chain may name one only if the calling
 * project handed it in through the `plugins` option:
 *
 *     require_once __DIR__ . '/src/Sekreto.php';
 *     require_once __DIR__ . '/plugins/hashicorp.php';
 *
 *     use Voxgig\Sekreto\Sekreto;
 *     use function Voxgig\Sekreto\Plugins\hashicorp;
 *
 *     $secrets = new Sekreto([
 *         'plugins' => [hashicorp()],
 *         'providers' => [
 *             ['kind' => 'env'],
 *             ['kind' => 'hashicorp', 'addr' => $addr, 'token' => $token],
 *         ],
 *     ]);
 *
 * or, for every kind at once, `allplugins()` from plugins/plugins.php. See
 * docs/design/plugin-providers.md.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto;

/**
 * Anything sekreto refuses to do: a bad name, a missing secret, a provider
 * that could not be reached.
 */
class SekretoError extends \RuntimeException
{
}

// voxgig/plugin first: the catalog, the host and the ref helpers below are
// its. `Plugin.php` finds the checkout, and is the only file in this port
// that looks for one.
require_once __DIR__ . '/../../plugin/plugin.php';

require_once __DIR__ . '/Addr.php';
require_once __DIR__ . '/Providers.php';

use Voxgig\Plugin\Catalog;
use Voxgig\Plugin\Host;
use Voxgig\Plugin\PluginError;

use function Voxgig\Plugin\check_tag;
use function Voxgig\Plugin\format_ref;
use function Voxgig\Plugin\make_catalog;
use function Voxgig\Plugin\make_host;

final class Name
{
    // `\z`-style anchors, not `$`. In Python, PCRE, Perl and .NET `$` also
    // matches BEFORE a final newline, so `api.token\n` was accepted here while the
    // canonical port rejected it - and `envkey` then produced the key
    // `API_TOKEN\n`, sending this port looking for a differently named file and
    // variable than the others.
    private const NAMEPART = '/\A[a-z0-9_]+\z/';

    /** Is this a well-formed secret name? */
    public static function valid($name): bool
    {
        if (!is_string($name) || '' === $name) {
            return false;
        }

        foreach (explode('.', $name) as $part) {
            if (1 !== preg_match(self::NAMEPART, $part)) {
                return false;
            }
        }

        return true;
    }

    public static function check($name): string
    {
        if (!self::valid($name)) {
            throw new SekretoError(
                'sekreto: invalid name: ' . (null === $name ? '' : (string) $name)
            );
        }

        return $name;
    }

    /** The environment-variable key for a name: `api.token` -> `API_TOKEN`. */
    public static function envkey(string $name, ?string $prefix = null): string
    {
        self::check($name);

        return ($prefix ?? '') . strtoupper(implode('_', explode('.', $name)));
    }

    /**
     * Where a name lives in a KV vault: `api.token` -> `api` / `token`.
     *
     * A single-segment name has no path of its own, so it becomes a secret
     * of that name with the conventional field `value`.
     *
     * @return array{path: string, field: string}
     */
    public static function vaultref(string $name): array
    {
        self::check($name);

        $parts = explode('.', $name);

        if (1 === count($parts)) {
            return ['path' => $parts[0], 'field' => 'value'];
        }

        $field = array_pop($parts);

        return ['path' => implode('/', $parts), 'field' => $field];
    }

    /**
     * A name flattened to one segment: `api.token` -> `api_token` (GCP
     * Secret Manager, `_`) or `api-token` (Azure Key Vault, `-`).
     *
     * Those stores have no path hierarchy and reject dots in ids, so the
     * dots become the store's conventional separator. With `-` as the
     * separator, underscores flatten too: Azure Key Vault's alphabet is
     * letters, digits and hyphens only, and a valid sekreto name like
     * `with_underscore` must still be representable there. (The resulting
     * `.`/`_` collision mirrors the documented envkey behaviour, where
     * both already map to `_`.)
     */
    public static function flatname(string $name, string $sep): string
    {
        self::check($name);

        $flat = implode($sep, explode('.', $name));

        return '-' === $sep ? str_replace('_', '-', $flat) : $flat;
    }

    /**
     * The AWS SSM Parameter Store name for a name: dots become the path
     * hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
     * `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
     */
    public static function awsparam(string $name, ?string $prefix = null): string
    {
        self::check($name);

        $base = $prefix ?? '';
        if ('' !== $base && !str_starts_with($base, '/')) {
            $base = '/' . $base;
        }
        $base = preg_replace('#/$#', '', $base);

        return $base . '/' . implode('/', explode('.', $name));
    }
}

/**
 * JSON text for a value that LEAVES the process.
 *
 * Two of `json_encode`'s defaults have to be turned off. It escapes `/` as
 * `\/`, a defence for JSON pasted inside an HTML script tag, and it escapes
 * every non-ASCII character as `\uXXXX`. Neither is wrong, and both made
 * php one of only three ports whose bytes differed: the rest emit a
 * secret's accented or non-Latin characters as the UTF-8 they already are,
 * and a slash as a slash. The writer's output is part of what the ports
 * agree on - the CLI line is compared byte for byte across all of them -
 * so php matches the rest.
 *
 * Use this for a request body, a returned secret, the CLI's line. A
 * `json_encode` whose text is decoded again without ever being emitted
 * needs no such care.
 */
function writejson($value): string
{
    return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
}

/**
 * Parse `.env` text into a map of raw keys to values.
 *
 * Deliberately small: `KEY=value`, optional `export`, `#` comments on their
 * own line, and single- or double-quoted values (double quotes also
 * unescape \n, \r, \t and \\). A line with no `=` is skipped.
 *
 * @return array<string, string>
 */
function parsedotenv($text): array
{
    $out = [];

    if (!is_string($text)) {
        return $out;
    }

    foreach (explode("\n", $text) as $rawline) {
        $line = trim(preg_replace('/\r$/', '', $rawline));

        if ('' === $line || str_starts_with($line, '#')) {
            continue;
        }

        $body = str_starts_with($line, 'export ') ? trim(substr($line, 7)) : $line;

        $eq = strpos($body, '=');
        if (false === $eq || 0 >= $eq) {
            continue;
        }

        $key = trim(substr($body, 0, $eq));
        $value = trim(substr($body, $eq + 1));

        if (2 <= strlen($value) && str_starts_with($value, '"') && str_ends_with($value, '"')) {
            $value = unescape(substr($value, 1, -1));
        } elseif (2 <= strlen($value) && str_starts_with($value, "'") && str_ends_with($value, "'")) {
            $value = substr($value, 1, -1);
        }

        $out[$key] = $value;
    }

    return $out;
}

function unescape(string $text): string
{
    $out = '';
    $index = 0;
    $len = strlen($text);

    while ($index < $len) {
        if ('\\' === $text[$index] && $index + 1 < $len) {
            $next = $text[$index + 1];
            $index += 2;
            $out .= match ($next) {
                'n' => "\n",
                'r' => "\r",
                't' => "\t",
                '\\' => '\\',
                '"' => '"',
                default => '\\' . $next,
            };
        } else {
            $out .= $text[$index];
            $index++;
        }
    }

    return $out;
}

/**
 * Replace known secret values in text with `[redacted]`.
 *
 * Only values of four characters or more are replaced: shorter ones are too
 * likely to appear in ordinary text, and redacting them would make logs
 * unreadable without making them safer.
 *
 * @param array<int, mixed> $values
 */
function redact($text, $values): string
{
    $out = is_string($text) ? $text : '';

    $usable = [];
    foreach ($values ?? [] as $value) {
        if (is_string($value) && 4 <= strlen($value)) {
            $usable[] = $value;
        }
    }

    // Longest first: a shorter secret that prefixes a longer one used to eat
    // the prefix and leave the rest in the log. $usable is our own array, so
    // sorting it does not reorder the caller's.
    usort($usable, fn ($left, $right) => strlen($right) <=> strlen($left));

    foreach ($usable as $value) {
        $out = implode('[redacted]', explode($value, $out));
    }

    return $out;
}

/**
 * The store name a live provider answers to.
 *
 * `describe()` opens with the provider's kind - `hashicorp:...`,
 * `dotenv:...`, plain `env` - so the kind is the natural default, and a
 * custom provider gets a sensible name without implementing anything
 * extra. A spec'd provider's store is its `name` or its `kind`, decided
 * before the provider exists.
 */
function storename(Provider $provider): string
{
    return explode(':', $provider->describe())[0];
}

/**
 * A plugin entry, checked to be a definition before the catalog sees it.
 *
 * Every plugin file holds a FUNCTION named after the definition it builds
 * - `hashicorp()` - because a definition holds closures and PHP has no
 * constant that can. Passing the function instead of calling it is
 * therefore the mistake this port makes easy, and a callable in the
 * catalog would fail deep inside voxgig/plugin with a message about a
 * definition name. Refused here instead, naming the call that was meant.
 *
 * @param mixed $plugin
 * @return array<string, mixed>
 */
function definitionof($plugin): array
{
    if (is_callable($plugin) && !is_array($plugin)) {
        $name = 'the plugin function';

        try {
            $fn = \Closure::fromCallable($plugin);
            $name = 'the function ' . (new \ReflectionFunction($fn))->getName();
        } catch (\Throwable $ignored) {
        }

        throw new SekretoError(
            'sekreto: not a plugin definition: ' . $name
            . ' - call it for the definition it holds'
        );
    }

    if (!is_array($plugin) || !isset($plugin['name']) || !is_string($plugin['name'])) {
        throw new SekretoError('sekreto: not a plugin definition: ' . describevalue($plugin));
    }

    return $plugin;
}

/** @param mixed $value */
function describevalue($value): string
{
    if (is_object($value)) {
        return 'an instance of ' . get_class($value);
    }
    if (is_array($value)) {
        return 'an array with no name';
    }
    if (null === $value) {
        return 'null';
    }

    return is_scalar($value) ? var_export($value, true) : gettype($value);
}

/**
 * The message for a kind the catalog does not hold.
 *
 * A kind sekreto has never heard of is a typo; a kind that exists as a
 * plugin but was not passed in is the split working as designed and
 * telling you what to pass. Collapsing the two was the first thing that
 * made the split confusing to use.
 *
 * @param mixed $kind
 */
function unknownkind($kind, Catalog $catalog): string
{
    $text = 'sekreto: unknown provider kind: ' . (null === $kind ? '' : (string) $kind)
        . ' (available: ' . implode(', ', $catalog->names()) . ')';

    if (is_string($kind) && in_array($kind, PLUGIN_KINDS, true)) {
        $text .= ' - ' . $kind
            . ' is a sekreto plugin, not built in: pass it in the plugins option';
    }

    return $text;
}

/**
 * A SekretoError that crossed the plugin boundary comes back out as
 * itself, byte for byte. Anything else is not sekreto's to rewrite.
 */
function unwrap(\Throwable $err): \Throwable
{
    if ($err instanceof PluginError && ERROR_CODE === $err->code
        && is_string($err->details['cause'] ?? null)
    ) {
        return new SekretoError($err->details['cause']);
    }

    return $err;
}

/**
 * The secrets facade: a chain of providers plus a cache.
 *
 * Two ways to read. `get` is transparent - it walks the chain and takes the
 * first hit, and the caller never learns which store answered. `getfrom` is
 * directed - it names the store, and only that store is asked.
 */
class Sekreto
{
    /** @var array<int, array{0: string, 1: Provider}> */
    private array $entries = [];
    private bool $docache;
    /** @var array<int, array{0: string, 1: string, 2: string}> */
    private array $cache = [];
    /**
     * Every value ever resolved, for redact(). Kept independently of the
     * read cache so that redaction still works when cache is off -
     * otherwise `cache: false` would silently disable redact() and leak
     * secrets to logs.
     *
     * @var array<int, string>
     */
    private array $seen = [];

    /**
     * The definitions this Sekreto can build. Read it for introspection:
     * `names()` is every kind this chain could have named.
     */
    public Catalog $catalog;

    /**
     * The voxgig/plugin host every spec'd provider is an instance of. Read
     * it for introspection - `list()` names each store's ref and status -
     * and nothing on it advances the chain.
     */
    public Host $host;

    /** @param array<string, mixed>|null $options */
    public function __construct(?array $options = null)
    {
        $opts = $options ?? [];

        // Built-ins first, then the plugins, into one catalog: a plugin
        // that names a built-in kind replaces it, which is how a host
        // substitutes an implementation and never an accident, because the
        // four names are documented.
        $defs = builtins();
        foreach ($opts['plugins'] ?? [] as $plugin) {
            $defs[] = definitionof($plugin);
        }

        $this->catalog = make_catalog($defs);
        $this->host = make_host(['catalog' => $this->catalog]);

        // (store, provider) pairs, in chain order. A provider handed in
        // live is backed by no instance; a spec'd one is an instance of its
        // kind on the host.
        foreach ($opts['providers'] ?? [] as $entry) {
            if ($entry instanceof Provider) {
                $this->entries[] = [storename($entry), $entry];
                continue;
            }

            $this->entries[] = $this->declare(is_array($entry) ? $entry : []);
        }

        $this->docache = false !== ($opts['cache'] ?? true);
    }

    /**
     * One chain entry, as a plugin instance.
     *
     * The instance is `kind` for a store named after its kind and
     * `kind$store` otherwise - `hashicorp$prod` - so `host->list()` reads
     * like the chain. A store name that is already taken gets a numbered
     * tag from the host instead, because two providers MAY share a store
     * name (a directed read walks both) and an instance ref may not.
     *
     * @param array<string, mixed> $spec
     * @return array{0: string, 1: Provider}
     */
    private function declare(array $spec): array
    {
        $kind = $spec['kind'] ?? null;

        if (!is_string($kind) || !$this->catalog->has($kind)) {
            throw new SekretoError(unknownkind($kind, $this->catalog));
        }

        $store = empty($spec['name']) ? $kind : $spec['name'];

        if (!check_tag($store)) {
            throw new SekretoError(
                'sekreto: invalid store name: ' . (is_string($store) ? $store : gettype($store))
            );
        }

        $ref = $store === $kind ? $kind : format_ref($kind, $store);
        $declare = ['options' => $spec];

        // `tag => '?'` is voxgig/plugin's explicit auto-tagging: the lowest
        // unused integer tag for this kind. The STORE name is untouched.
        if (null !== $this->host->instance($ref)) {
            $ref = $kind;
            $declare['tag'] = '?';
        }

        try {
            // `load` runs the definition's `define`, which builds the
            // provider from the spec; `activate` takes the instance live.
            // Nothing is contacted by either: a provider opens nothing
            // until its first lookup.
            $entry = $this->host->load($ref, $declare);
            $this->host->activate($entry->ref);
        } catch (\Throwable $err) {
            throw unwrap($err);
        }

        return [$store, $this->host->exports($entry->ref . '/' . PROVIDER_EXPORT)];
    }

    /** The secret, or a SekretoError if no provider has it. */
    public function get(string $name): string
    {
        $found = $this->try($name);

        if (null === $found) {
            throw new SekretoError('sekreto: unknown secret: ' . $name);
        }

        return $found;
    }

    /** The secret, or null if no provider has it. */
    public function try(string $name): ?string
    {
        return $this->resolve('', $name, $this->entries);
    }

    /**
     * The secret from one named store, or a SekretoError if that store does
     * not have it.
     */
    public function getfrom(string $store, string $name): string
    {
        $found = $this->tryfrom($store, $name);

        if (null === $found) {
            throw new SekretoError('sekreto: unknown secret: ' . $store . ':' . $name);
        }

        return $found;
    }

    /**
     * The secret from one named store, or null if that store does not have
     * it.
     *
     * Naming a store that is not in the chain is an error, not a miss: `try`
     * already means "this store may not have it", so it cannot also mean
     * "this store may not exist" without hiding a typo.
     */
    public function tryfrom(string $store, string $name): ?string
    {
        $matching = array_values(
            array_filter($this->entries, fn(array $entry) => $entry[0] === $store)
        );

        if (0 === count($matching)) {
            throw new SekretoError('sekreto: unknown store: ' . $store);
        }

        return $this->resolve($store, $name, $matching);
    }

    /** @param array<int, array{0: string, 1: Provider}> $entries */
    private function resolve(string $store, string $name, array $entries): ?string
    {
        Name::check($name);

        if ($this->docache) {
            foreach ($this->cache as $cached) {
                if ($cached[0] === $store && $cached[1] === $name) {
                    return $cached[2];
                }
            }
        }

        foreach ($entries as [$entrystore, $provider]) {
            $found = $provider->lookup($name);

            if (null !== $found) {
                if ($this->docache) {
                    $this->cache[] = [$store, $name, $found];
                }
                $this->seen[] = $found;
                return $found;
            }
        }

        return null;
    }

    /** Does any provider have this secret? */
    public function has(string $name): bool
    {
        return null !== $this->try($name);
    }

    /** Does this named store have this secret? */
    public function hasin(string $store, string $name): bool
    {
        return null !== $this->tryfrom($store, $name);
    }

    /**
     * Every named secret at once. Missing ones are an error.
     *
     * @param array<int, string> $names
     * @return array<string, string>
     */
    public function all(array $names): array
    {
        $out = [];

        foreach ($names as $name) {
            $out[$name] = $this->get($name);
        }

        return $out;
    }

    /**
     * A description of each provider, in resolution order.
     *
     * @return array<int, string>
     */
    public function sources(): array
    {
        return array_values(array_map(fn(array $entry) => $entry[1]->describe(), $this->entries));
    }

    /**
     * The name of each store that can be named by `getfrom`, in resolution
     * order and without repeats.
     *
     * @return array<int, string>
     */
    /**
     * What a Sekreto shows of itself when something prints it.
     *
     * `var_dump`, `print_r` and `var_export` all reach private properties,
     * and $cache and $seen between them hold every value this chain has
     * ever resolved - so one ordinary debugging call writes every secret
     * out.
     *
     * @return array<string, mixed>
     */
    public function __debugInfo(): array
    {
        return ['stores' => $this->stores()];
    }

    public function stores(): array
    {
        $out = [];

        foreach ($this->entries as [$store, $provider]) {
            if (!in_array($store, $out, true)) {
                $out[] = $store;
            }
        }

        return $out;
    }

    /**
     * Replace every value this Sekreto has resolved with `[redacted]`.
     *
     * Works whether or not caching is enabled: the redaction list is kept
     * independently of the read cache.
     */
    public function redact(string $text): string
    {
        return redact($text, $this->seen);
    }

    /** Drop cached values, so the next `get` asks the providers again. */
    public function refresh(): void
    {
        $this->cache = [];
    }

    /**
     * Tear the chain down: every plugin instance is deactivated and
     * unloaded, in reverse, releasing whatever a provider acquired at
     * activation. Afterwards there is nothing to read from - `get` reports
     * every secret unknown - and the cache is dropped, though `redact`
     * still knows every value that was ever resolved.
     */
    public function close(): void
    {
        $this->host->close();
        $this->entries = [];
        $this->cache = [];
    }
}

/**
 * Make a Sekreto from options.
 *
 * @param array<string, mixed>|null $options
 */
function sekreto(?array $options = null): Sekreto
{
    return new Sekreto($options);
}
