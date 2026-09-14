<?php
// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (php/plugins/aws.php)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.

/**
 * AWS Secrets Manager and SSM Parameter Store, as voxgig/plugin
 * definitions - TWO kinds from one file, because they share request signing
 * and the credential chain.
 *
 * A PLUGIN, not a built-in, and the sharpest instance of why: it opens a
 * socket AND it signs, so `sigv4.php` - the only hashing in this port - is
 * required from here and from nowhere in the core.
 */

declare(strict_types=1);

namespace Voxgig\Sekreto\Plugins;

require_once __DIR__ . '/../src/Providers.php';
require_once __DIR__ . '/../src/Addr.php';
require_once __DIR__ . '/httpjson.php';
require_once __DIR__ . '/sigv4.php';

use Voxgig\Sekreto\Name;
use Voxgig\Sekreto\Provider;
use Voxgig\Sekreto\SekretoError;

use function Voxgig\Sekreto\checkaddr;
use function Voxgig\Sekreto\providerplugin;
use function Voxgig\Sekreto\writejson;

/** The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now. */
function awsnow(): string
{
    return gmdate('Ymd\THis\Z');
}

/**
 * Region and credentials, from config first and the standard AWS_*
 * environment variables second - those are AWS's own convention, and a
 * pod or CI job that has them set should just work. Missing either is an
 * error: an AWS store with no credentials could not answer.
 *
 * @param array<string, mixed> $opts
 * @return array{region: string, keyid: string, secret: string, session: ?string}
 */
function awsauth(array $opts): array
{
    $region = ($opts['region'] ?? null)
        ?: (getenv('AWS_REGION') ?: (getenv('AWS_DEFAULT_REGION') ?: ''));
    $keyid = ($opts['keyid'] ?? null) ?: (getenv('AWS_ACCESS_KEY_ID') ?: '');
    $secret = ($opts['secret'] ?? null) ?: (getenv('AWS_SECRET_ACCESS_KEY') ?: '');
    $session = ($opts['session'] ?? null) ?: (getenv('AWS_SESSION_TOKEN') ?: null);

    if ('' === $region) {
        throw new SekretoError('sekreto: aws: no region (set region or AWS_REGION)');
    }
    if ('' === $keyid || '' === $secret) {
        throw new SekretoError(
            'sekreto: aws: no credentials'
            . ' (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)'
        );
    }

    return ['region' => $region, 'keyid' => $keyid, 'secret' => $secret, 'session' => $session];
}

/**
 * One signed call to an AWS JSON-1.1 API.
 *
 * @param array<string, mixed> $opts
 * @param array<string, mixed> $payload
 * @return array{0: int, 1: mixed}
 */
function awscall(array $opts, string $service, string $target, array $payload): array
{
    $auth = awsauth($opts);
    // The China partition lives under its own suffix; every other
    // commercial region is plain amazonaws.com.
    $suffix = str_starts_with($auth['region'], 'cn-') ? '.amazonaws.com.cn' : '.amazonaws.com';
    $addr = ($opts['addr'] ?? null)
        ?: 'https://' . $service . '.' . $auth['region'] . $suffix;
    checkaddr($addr);

    $url = preg_replace('#/$#', '', $addr) . '/';
    // writejson, so the body signed here is byte-identical to the canonical
    // port's JSON.stringify output: unescaped slashes AND unescaped unicode.
    // With only the slashes turned off, a non-ASCII secret path still signed
    // different bytes from every other port.
    $body = writejson($payload);
    $headers = [
        'content-type' => 'application/x-amz-json-1.1',
        'x-amz-target' => $target,
    ];

    $signed = sigv4([
        'method' => 'POST',
        'url' => $url,
        'headers' => $headers,
        'body' => $body,
        'service' => $service,
        'region' => $auth['region'],
        'keyid' => $auth['keyid'],
        'secret' => $auth['secret'],
        'session' => $auth['session'],
        'datetime' => awsnow(),
    ]);

    $lines = [];
    foreach (array_merge($headers, $signed) as $key => $value) {
        $lines[] = $key . ': ' . $value;
    }

    return fetchjson('POST', $url, $lines, $body);
}

/**
 * Does this AWS error body name one of the not-found types? Those are a
 * miss; every other failure is a store that could not answer.
 *
 * @param array<int, string> $types
 */
function awsmiss(mixed $body, array $types): bool
{
    $errtype = is_array($body) && is_string($body['__type'] ?? null) ? $body['__type'] : '';

    foreach ($types as $name) {
        if (str_contains($errtype, $name)) {
            return true;
        }
    }

    return false;
}

/**
 * AWS Secrets Manager.
 *
 * `api.token` reads the secret named `api` (the vaultref path, so
 * `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
 * SecretString - the AWS idiom of one JSON map per secret. A SecretString
 * that is not JSON is the value itself, under the conventional field
 * `value`. Requests are SigV4-signed in-tree; see sigv4.php.
 */
class AwsSecretsProvider implements Provider
{
    /** @param array<string, mixed> $opts */
    public function __construct(private array $opts = [])
    {
    }

    public function lookup(string $name): ?string
    {
        $ref = Name::vaultref($name);

        [$status, $body] = awscall(
            $this->opts,
            'secretsmanager',
            'secretsmanager.GetSecretValue',
            ['SecretId' => $ref['path']]
        );

        if (400 === $status && awsmiss($body, ['ResourceNotFoundException'])) {
            return null;
        }

        if (200 !== $status) {
            throw new SekretoError('sekreto: aws secretsmanager error: ' . $status);
        }

        $text = $body['SecretString'] ?? null;

        if (!is_string($text)) {
            // A binary secret has no fields to address; only the conventional
            // `value` field can mean "the bytes themselves".
            $bin = $body['SecretBinary'] ?? null;
            if (is_string($bin) && 'value' === $ref['field']) {
                // strict: base64_decode SKIPS characters outside the
                // alphabet by default, so a corrupted payload decoded to
                // plausible-looking bytes that were then returned as the
                // secret. A store that answered incoherently is an error.
                $decoded = base64_decode($bin, true);
                if (false === $decoded) {
                    throw new SekretoError('sekreto: aws secretsmanager: undecodable secret');
                }

                return $decoded;
            }
            return null;
        }

        // Decoded without assoc, so a JSON object is distinguishable from a
        // JSON array: only an object carries named fields.
        $parsed = json_decode($text);

        if ($parsed instanceof \stdClass) {
            $value = $parsed->{$ref['field']} ?? null;
            return null === $value ? null : (string) $value;
        }

        // A plain-string secret is the whole value; it has no named fields.
        return 'value' === $ref['field'] ? $text : null;
    }

    // Config only, never the environment: describe() feeds the spec's
    // sources group, which must answer the same everywhere.
    public function describe(): string
    {
        return 'awssecrets:' . ($this->opts['region'] ?? '');
    }
}

/**
 * AWS SSM Parameter Store.
 *
 * `db.pass.main` reads the parameter `/db/pass/main` (under an optional
 * prefix path), decrypted. Parameter Store carries flat strings, so there
 * is no field indirection.
 */
class AwsParamsProvider implements Provider
{
    /** @param array<string, mixed> $opts */
    public function __construct(private array $opts = [])
    {
    }

    public function lookup(string $name): ?string
    {
        [$status, $body] = awscall($this->opts, 'ssm', 'AmazonSSM.GetParameter', [
            'Name' => Name::awsparam($name, $this->opts['prefix'] ?? null),
            'WithDecryption' => true,
        ]);

        if (400 === $status && awsmiss($body, ['ParameterNotFound'])) {
            return null;
        }

        if (200 !== $status) {
            throw new SekretoError('sekreto: aws ssm error: ' . $status);
        }

        $value = $body['Parameter']['Value'] ?? null;

        return null === $value ? null : (string) $value;
    }

    public function describe(): string
    {
        return 'awsparams:' . ($this->opts['region'] ?? '') . ($this->opts['prefix'] ?? '');
    }
}

/**
 * The `awssecrets` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function awssecrets(): array
{
    return providerplugin('awssecrets', fn(array $spec) => new AwsSecretsProvider($spec));
}

/**
 * The `awsparams` provider kind, as a voxgig/plugin definition. Pass it to
 * `Sekreto` in the `plugins` option; nothing else loads it.
 *
 * @return array<string, mixed>
 */
function awsparams(): array
{
    return providerplugin('awsparams', fn(array $spec) => new AwsParamsProvider($spec));
}
