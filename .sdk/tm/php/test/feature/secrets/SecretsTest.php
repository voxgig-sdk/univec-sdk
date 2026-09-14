<?php
declare(strict_types=1);

// Behavioural tests for the secrets feature (vendored @voxgig/sekreto) -
// the php port of tm/ts/test/feature/secrets/Secrets.test.ts.
//
// The contract under test: the `apikey` OPTION keeps its exact old meaning
// and always wins, because the feature places it FIRST in the provider
// chain (a `memory` store named 'options') - explicit-beats-lookup falls
// out of sekreto's first-hit rule rather than from special-case logic. With
// the feature inactive nothing changes at all. With it active and the
// option unset, the chain (env, a custom provider, a vault) supplies the
// credential instead.
//
// This file lives in the test `feature/` container on purpose: `target add`
// trims it, along with the feature source and the vendored library, for a
// project whose model does not select `secrets`.
//
// The credential is asserted ON THE WIRE: a live-mode client with a
// recording system.fetch, driven through real entity operations AND through
// `direct()` and `graphql()`. An options-level assertion would pass for a
// port that never consults the value, and the raw paths run NO feature
// hooks - which is exactly why resolution lives at the transport seam.

require_once __DIR__ . '/../../../projectname_sdk.php';

use PHPUnit\Framework\TestCase;

// PLACEHOLDER-PREFIXED, all three classes in this file. A generated PHP SDK
// uses no namespaces and composer classmaps both `types/` and `test/`, so a
// bare `SecretsWire` here is a name an API entity could also claim - and PHP
// answers a redeclaration with a fatal, not a warning (helpers/naming.ts
// PHP_SDK_CLASSES, and test/php-sdk-classes.test.ts). `Univec`
// substitutes to this SDK's own name, which no bare entity type can equal.
//
// The recording transport: system.fetch for a LIVE client, scripting one
// status per API call (the last repeating) and a token endpoint for the
// exchange tests.
class UnivecSecretsWire
{
    /** @var array<int,array<string,mixed>> */
    public array $calls = [];
    /** @var array<int,int> */
    public array $apistatus = [200];
    /** @var array<int,string> */
    public array $tokens = ['ACCESS01', 'ACCESS02', 'ACCESS03'];
    public string $tokenpath = 'auth/token';
    public string $respfield = 'access_token';

    private int $issued = 0;
    private int $apicalls = 0;

    // The callable the SDK options take as system.fetch.
    public function fetch(): callable
    {
        return function (string $fullurl, array $fetchdef): array {
            return $this->record($fullurl, $fetchdef);
        };
    }

    public function record(string $fullurl, array $fetchdef): array
    {
        $headers = is_array($fetchdef['headers'] ?? null) ? $fetchdef['headers'] : [];
        $this->calls[] = [
            'url' => $fullurl,
            'auth' => $headers['authorization'] ?? null,
            'has' => array_key_exists('authorization', $headers),
            'body' => $fetchdef['body'] ?? null,
        ];

        if ($this->istoken($fullurl)) {
            $token = $this->tokens[min($this->issued, count($this->tokens) - 1)];
            $this->issued++;
            $payload = [$this->respfield => $token];
            return [[
                'status' => 200, 'statusText' => 'OK', 'headers' => [],
                'json' => function () use ($payload) { return $payload; },
            ], null];
        }

        $status = $this->apistatus[min($this->apicalls, count($this->apistatus) - 1)];
        $this->apicalls++;
        $payload = ['ok' => $status < 400];
        return [[
            'status' => $status, 'statusText' => 'X', 'headers' => [],
            'json' => function () use ($payload) { return $payload; },
        ], null];
    }

    /** The recorded calls that did NOT go to the token endpoint. */
    public function api(): array
    {
        return array_values(array_filter($this->calls,
            fn(array $c) => !$this->istoken((string)$c['url'])));
    }

    public function token(): array
    {
        return array_values(array_filter($this->calls,
            fn(array $c) => $this->istoken((string)$c['url'])));
    }

    private function istoken(string $url): bool
    {
        return str_ends_with($url, '/' . $this->tokenpath);
    }
}

class UnivecSecretsTest extends TestCase
{
    // The env-var base for this SDK, as every other generated env var
    // spells it.
    private const ENVPREFIX = 'PROJECTENV_TEST_SECRETS_';

    /** @var array<int,string> */
    private array $touched = [];

    protected function tearDown(): void
    {
        foreach ($this->touched as $name) {
            putenv(self::ENVPREFIX . $name);
        }
        $this->touched = [];
    }

    private function setenv(string $name, string $value): void
    {
        $this->touched[] = $name;
        putenv(self::ENVPREFIX . $name . '=' . $value);
    }

    private function clearenv(string $name): void
    {
        $this->touched[] = $name;
        putenv(self::ENVPREFIX . $name);
    }

    // -----------------------------------------------------------------
    // Support.

    // The Authorization header carries the SPEC's credential prefix, which
    // a TEMPLATE cannot know - so assert on the CREDENTIAL and let the
    // prefix be whatever this SDK's API declares.
    private function assertCredential(mixed $header, string $token): void
    {
        $ok = $header === $token
            || (is_string($header) && str_ends_with($header, ' ' . $token));
        $this->assertTrue($ok,
            'expected the authorization header to carry ' . $token .
            ', got: ' . var_export($header, true));
    }

    private function secretsFeatureOf($client): ?UnivecSecretsFeature
    {
        foreach ($client->features as $f) {
            if ($f instanceof UnivecSecretsFeature) {
                return $f;
            }
        }
        return null;
    }

    // Construct the client and ADOPT the feature via `extend` ONLY when the
    // generated config did not already install it - when this SDK was
    // generated with `secrets` model-active, the ordinary factory path
    // builds the instance, and adding a second via extend would DOUBLE the
    // feature: two transport wraps, two resolutions, and a token purchase
    // the assertions cannot account for. (go's withSecrets, py's
    // _has_feature and rb's with_secrets guard the same way.)
    private function withSecrets(callable $build)
    {
        $client = $build(false);
        if ($this->secretsFeatureOf($client) === null) {
            $client = $build(true);
        }
        return $client;
    }

    /** @return array<string,mixed> */
    private function secretsOpts(array $extra = []): array
    {
        $fopts = array_merge([
            'active' => true,
            'providers' => [['kind' => 'env', 'prefix' => self::ENVPREFIX]],
        ], $extra);
        return ['secrets' => $fopts];
    }

    // A LIVE client carrying the secrets feature, wired to the recorder.
    private function secretsClient(UnivecSecretsWire $wire, array $sdkopts = [])
    {
        $opts = array_merge([
            'base' => 'http://secrets.test/api',
            'system' => ['fetch' => $wire->fetch()],
        ], $sdkopts);

        return $this->withSecrets(function (bool $adopt) use ($opts) {
            if ($adopt) {
                $opts['extend'] = [new UnivecSecretsFeature()];
            }
            return new UnivecSDK($opts);
        });
    }

    // A custom provider, as php's option pipeline can carry one: an ARRAY
    // OF CALLABLES. `Struct::clone` flattens a class instance to a stdClass
    // (its methods lost) but leaves closures alone, so this is the shape a
    // provider written in code must take - the exact parallel of the ts
    // object literal, and py's `_LiveProvider` contract.
    private function customProvider(callable $lookup, ?callable $describe = null): array
    {
        $spec = ['lookup' => $lookup];
        if ($describe !== null) {
            $spec['describe'] = $describe;
        }
        return $spec;
    }

    // The entity accessors this SDK generated ($client->Moon(),
    // $client->Planet(), ...). Read off the class rather than from a name
    // convention: this file is a TEMPLATE and no project's entity names are
    // known here.
    private function entityAccessors($client): array
    {
        $out = [];
        $rc = new \ReflectionClass($client);
        foreach ($rc->getMethods(\ReflectionMethod::IS_PUBLIC) as $m) {
            if ($m->isStatic() || $m->isConstructor()) {
                continue;
            }
            if (1 === preg_match('/^[A-Z]/', $m->getName())) {
                $out[] = $m->getName();
            }
        }
        return $out;
    }

    // Perform real entity operations until `stop` reports the observable
    // state the test is waiting for. Each op's own outcome is irrelevant (no
    // seeded data, a scripted response); an op the API does not define fails
    // before it reaches the transport, which is why several may need
    // driving.
    private function driveUntil($client, string $what, callable $stop): void
    {
        foreach ($this->entityAccessors($client) as $accessor) {
            try {
                $ent = $client->$accessor();
            } catch (\Throwable $e) {
                continue;
            }
            foreach (['list', 'load'] as $opname) {
                if (!method_exists($ent, $opname)) {
                    continue;
                }
                try {
                    $ent->$opname();
                } catch (\Throwable $e) {
                    // The op's own failure is not the assertion.
                }
                if ($stop()) {
                    return;
                }
            }
        }
        $this->fail('no entity operation ' . $what . ' - nothing to assert on');
    }

    // Drive ops until one request reached the recorder.
    private function driveOp($client, UnivecSecretsWire $wire): void
    {
        $before = count($wire->api());
        $this->driveUntil($client, 'reached the transport',
            fn() => $before < count($wire->api()));
    }

    // -----------------------------------------------------------------
    // The feature-inactive baseline: bit-identical behaviour.

    public function testInactiveApikeyOptionBehavesExactlyAsBefore(): void
    {
        $client = UnivecSDK::test(null, ['apikey' => 'OPTKEY01']);
        $fetchdef = $client->prepare(['path' => '/']);
        $this->assertCredential($fetchdef['headers']['authorization'] ?? null, 'OPTKEY01');

        $this->assertNull($this->secretsFeatureOf($client),
            'no activation and no extend: the feature must not be installed');
    }

    public function testInactiveNoApikeyMeansNoAuthorizationHeader(): void
    {
        $client = UnivecSDK::test(null, null);
        $fetchdef = $client->prepare(['path' => '/']);
        $this->assertArrayNotHasKey('authorization', $fetchdef['headers']);
    }

    // -----------------------------------------------------------------
    // Active: the provider chain, driven through real entity operations.

    public function testApikeyOptionStillWinsOverTheChain(): void
    {
        $this->setenv('APIKEY', 'ENVKEY01');
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'apikey' => 'OPTKEY01',
            'feature' => $this->secretsOpts(),
        ]);

        $this->driveOp($client, $wire);
        $this->assertCredential($wire->api()[0]['auth'], 'OPTKEY01');

        // The explicit option is a real store, not a special case: a
        // directed read names it like any other.
        $feature = $this->secretsFeatureOf($client);
        $this->assertNotNull($feature, 'the extend seam did not install the feature');
        $this->assertSame('OPTKEY01', $feature->sekreto()->getfrom('options', 'apikey'));
    }

    public function testAnOmittedApikeyDefersToTheChainAtTheTransportSeam(): void
    {
        $this->setenv('APIKEY', 'ENVKEY02');
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, ['feature' => $this->secretsOpts()]);

        // Before any op, nothing has been resolved.
        $this->assertSame('', $client->options_map()['apikey']);

        $this->driveOp($client, $wire);

        // Resolution happens AT THE TRANSPORT - the one seam every wire path
        // crosses - so the credential is ON THE WIRE, not merely resolved.
        $this->assertCredential($wire->api()[0]['auth'], 'ENVKEY02');
        $this->assertSame('ENVKEY02', $this->secretsFeatureOf($client)->credential());

        // FEATURE STATE is the credential's only home. The options map -
        // which `options_map()` hands to any caller, which every concurrent
        // operation reads, and which a debug or audit feature may print -
        // must be exactly as the caller left it: a vault secret has no
        // business there. (go's `cred` field, secrets_feature.go, for the
        // same reason.) The consequence is deliberate and documented: a
        // chain-resolved credential is not visible to `prepare(...)`, which
        // reports the OPTIONS. Publication cannot fix that anyway - nothing
        // is resolved until a request crosses the transport, so the FIRST
        // prepare() is unauthenticated either way, and with a broken chain
        // publication yields a request carrying neither a credential nor an
        // error.
        $this->assertSame('', $client->options_map()['apikey'],
            'the chain credential must never be written into the client options');
    }

    // The same pin where it matters most: `auth: null` is the caller saying
    // NO credential may be sent. Nothing goes on the wire - and nothing is
    // parked in the options map either, where it would outlive the request
    // and reach every reader of options_map().
    public function testTheChainCredentialIsNeverParkedInTheOptionsMap(): void
    {
        $this->setenv('APIKEY', 'SHOULD_NOT_SEND');
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'auth' => null,
            'feature' => $this->secretsOpts(),
        ]);

        $this->driveOp($client, $wire);

        $this->assertFalse($wire->api()[0]['has'],
            'auth null must suppress the credential, got ' .
            var_export($wire->api()[0]['auth'], true));
        $this->assertSame('', $client->options_map()['apikey'],
            'the suppressed secret was parked in the client options');

        // Nor may it surface through the fetchdef prepare() builds.
        $fetchdef = $client->prepare(['path' => '/']);
        $this->assertArrayNotHasKey('authorization', $fetchdef['headers']);
    }

    public function testCustomProvidersAreAcceptedVerbatim(): void
    {
        $asked = [];
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(
                    function (string $name) use (&$asked) {
                        $asked[] = $name;
                        return 'CUSTOM01';
                    })],
            ]],
        ]);

        $this->driveOp($client, $wire);
        $this->assertCredential($wire->api()[0]['auth'], 'CUSTOM01');
        $this->assertSame('apikey', $asked[0]);
    }

    // php cannot carry a provider CLASS INSTANCE through the option
    // pipeline: `Struct::clone` flattens any object to a stdClass and its
    // methods are lost. That must be a loud, directive failure rather than
    // a chain that silently resolves nothing - and, being a failure, it
    // must fail CLOSED.
    public function testAProviderObjectIsRefusedWithAnActionableError(): void
    {
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [new \stdClass()],
            ]],
        ]);

        $res = $client->direct(['path' => '/probe']);
        $this->assertFalse($res['ok'], 'a broken chain must refuse the request');
        $this->assertStringContainsString(
            'A provider OBJECT cannot reach this feature', (string)$res['err']);
        $this->assertCount(0, $wire->calls);
    }

    public function testAMissEverywhereLeavesTheHeaderOff(): void
    {
        $this->clearenv('APIKEY');
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, ['feature' => $this->secretsOpts()]);

        $this->driveOp($client, $wire);
        $this->assertFalse($wire->api()[0]['has'],
            'a chain MISS must fall through to an unauthenticated request, got ' .
            var_export($wire->api()[0]['auth'], true));
    }

    public function testAProviderErrorFailsTheOpAndNothingReachesTheWire(): void
    {
        $asked = false;
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(
                    function (string $_name) use (&$asked) {
                        $asked = true;
                        throw new \Voxgig\Sekreto\SekretoError('vault unreachable');
                    })],
            ]],
        ]);

        // A full closure, not an arrow function: `fn()` captures by VALUE at
        // creation, so an arrow function here would keep reading the `false`
        // the flag held before any provider ran, and the drive would give up
        // without ever noticing the chain had been consulted.
        $this->driveUntil($client, 'consulted the chain',
            function () use (&$asked) { return $asked; });

        $this->assertCount(0, $wire->api(),
            'a broken vault must never yield a request');
    }

    // The entity pipeline turns the refusal into a thrown SDK error
    // carrying the feature's own code - never a silent unauthenticated
    // send.
    public function testAProviderErrorThrowsAnSdkErrorOnTheEntityPath(): void
    {
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(
                    function (string $_name) {
                        throw new \Voxgig\Sekreto\SekretoError('vault unreachable');
                    })],
            ]],
        ]);

        $accessor = $this->entityAccessors($client)[0] ?? null;
        $this->assertNotNull($accessor, 'no entity accessor - nothing to assert on');

        $caught = null;
        try {
            $client->$accessor()->list();
        } catch (UnivecError $e) {
            $caught = $e;
        }

        $this->assertNotNull($caught, 'the entity path must fail closed');
        $this->assertStringContainsString('vault unreachable', $caught->msg);
        $this->assertCount(0, $wire->api());
    }

    // MISS vs ERROR, the invariant the whole feature is worth having for,
    // asserted as a PAIR on the same two-provider chain: a store that does
    // not hold the secret falls through to the next one...
    public function testAMissFallsThroughToTheNextProvider(): void
    {
        $this->setenv('APIKEY', 'ENVKEY04');
        $asked = false;
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [
                    $this->customProvider(function (string $_name) use (&$asked) {
                        $asked = true;
                        return null;
                    }),
                    ['kind' => 'env', 'prefix' => self::ENVPREFIX],
                ],
            ]],
        ]);

        $this->driveOp($client, $wire);
        $this->assertTrue($asked, 'the first provider was never consulted');
        $this->assertCredential($wire->api()[0]['auth'], 'ENVKEY04');
    }

    // ...while a store that COULD NOT ANSWER fails the operation, even
    // though the very next provider in the chain holds the secret. A broken
    // vault never degrades into an unauthenticated - or a
    // differently-authenticated - request.
    public function testAnErrorFailsTheOpEvenThoughALaterProviderHasTheSecret(): void
    {
        $this->setenv('APIKEY', 'ENVKEY05');
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [
                    $this->customProvider(function (string $_name) {
                        throw new \Voxgig\Sekreto\SekretoError('vault unreachable');
                    }),
                    ['kind' => 'env', 'prefix' => self::ENVPREFIX],
                ],
            ]],
        ]);

        $res = $client->direct(['path' => '/probe']);
        $this->assertFalse($res['ok'], 'an ERROR must not fall through to the next provider');
        $this->assertSame('secrets_provider', $res['err']->sdk_code);
        $this->assertCount(0, $wire->calls);
    }

    public function testAProviderRecoversAfterATransientFailure(): void
    {
        $calls = 0;
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(
                    function (string $_name) use (&$calls) {
                        $calls++;
                        if (1 === $calls) {
                            throw new \Voxgig\Sekreto\SekretoError('vault unreachable');
                        }
                        return 'RECOVERED01';
                    })],
            ]],
        ]);

        // The first op fails closed; a failed resolution is never cached, so
        // the next op asks the chain again and succeeds.
        $this->driveUntil($client, 'consulted the chain',
            function () use (&$calls) { return 0 < $calls; });
        $this->assertCount(0, $wire->api(), 'the first op must not reach the wire');

        $this->driveOp($client, $wire);
        $this->assertCredential($wire->api()[0]['auth'], 'RECOVERED01');
    }

    // With `cache: false`, a provider that answered once and then reports a
    // MISS (a revoked secret) must RETRACT the credential: nothing the
    // feature resolved may keep going out on the wire.
    public function testAnUncachedMissRetractsTheCredential(): void
    {
        $have = true;
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'cache' => false,
                'providers' => [$this->customProvider(
                    function (string $_name) use (&$have) {
                        return $have ? 'REVOCABLE01' : null;
                    })],
            ]],
        ]);

        $this->driveOp($client, $wire);
        $this->assertCredential($wire->api()[0]['auth'], 'REVOCABLE01');

        $have = false;

        $this->driveOp($client, $wire);
        $api = $wire->api();
        $last = $api[count($api) - 1];
        $this->assertFalse($last['has'] && '' !== (string)$last['auth'],
            'after the chain reports a miss the retracted credential must not go out; ' .
            'the wire saw ' . var_export($last['auth'], true));
    }

    // A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this
    // feature used to override from the layer above.
    //
    // DEFAULT caching here, which is the whole point: `cache: true` is
    // about holding a HIT, and caching the settled resolution after a miss
    // meant the chain was never asked again for the life of the client. A
    // secret provisioned after startup (a mounted file, a vault policy
    // granted a minute late) was invisible forever, and the only workaround
    // was giving up hit caching entirely.
    public function testACachedMissIsReasked(): void
    {
        $present = false;
        $calls = 0;
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(
                    function (string $_name) use (&$present, &$calls) {
                        $calls++;
                        return $present ? 'LATEKEY01' : null;
                    })],
            ]],
        ]);

        $this->driveOp($client, $wire);
        $first = $wire->api()[0];
        $this->assertFalse($first['has'] && '' !== (string)$first['auth'],
            'the chain has nothing yet, so no credential should go out');

        $asked = $calls;
        $this->assertGreaterThan(0, $asked);

        // The secret is provisioned while the client is live.
        $present = true;

        $this->driveOp($client, $wire);
        $api = $wire->api();
        $this->assertCredential($api[count($api) - 1]['auth'], 'LATEKEY01');

        $this->assertGreaterThan($asked, $calls,
            'the MISS was cached: a secret that appears later can never be picked up');
    }

    // The other half of the same rule: a HIT is still cached by default, so
    // the fix above must not turn every request into a chain walk.
    public function testACachedHitIsKept(): void
    {
        $calls = 0;
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(
                    function (string $_name) use (&$calls) {
                        $calls++;
                        return 'STABLEKEY01';
                    })],
            ]],
        ]);

        $this->driveOp($client, $wire);
        $this->driveOp($client, $wire);

        $this->assertSame(1, $calls,
            'a hit must be cached under the default cache: true');
    }

    public function testAuthNullSuppressesTheCredentialChainOrNoChain(): void
    {
        $this->setenv('APIKEY', 'ENVKEY03');
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'auth' => null,
            'apikey' => 'OPTKEY01',
            'feature' => $this->secretsOpts(),
        ]);

        $this->driveOp($client, $wire);

        $this->assertFalse($wire->api()[0]['has'],
            'auth null must suppress the credential, got ' .
            var_export($wire->api()[0]['auth'], true));

        // The suppression survives option validation rather than being
        // replaced by the optspec's default auth map.
        $opts = $client->options_map();
        $this->assertTrue(array_key_exists('auth', $opts),
            'options.auth must stay a present null');
        $this->assertNull($opts['auth']);
    }

    // -----------------------------------------------------------------
    // The RAW paths - direct and graphql - run no feature hooks at all, so
    // for them the transport seam is the ONLY place resolution can happen.

    public function testDirectCarriesTheChainCredentialAndFailsClosed(): void
    {
        $this->setenv('APIKEY', 'DIRECTKEY01');
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, ['feature' => $this->secretsOpts()]);

        $res = $client->direct(['path' => '/direct-probe']);
        $this->assertTrue($res['ok'], 'direct refused');
        $this->assertCount(1, $wire->api());
        $this->assertCredential($wire->api()[0]['auth'], 'DIRECTKEY01');

        // And fail-closed holds for raw access too: a broken chain refuses
        // the direct call before anything reaches the wire.
        $brokenwire = new UnivecSecretsWire();
        $broken = $this->secretsClient($brokenwire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(function (string $_name) {
                    throw new \Voxgig\Sekreto\SekretoError('vault unreachable');
                })],
            ]],
        ]);

        $res = $broken->direct(['path' => '/direct-probe']);
        $this->assertFalse($res['ok'], 'a broken chain must refuse the raw path fail-closed');
        $this->assertSame('secrets_provider', $res['err']->sdk_code);
        $this->assertCount(0, $brokenwire->calls,
            'a broken vault must never yield a request on the raw path');
    }

    public function testGraphqlCarriesTheChainCredentialAndFailsClosed(): void
    {
        $this->setenv('APIKEY', 'GQLKEY01');
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, ['feature' => $this->secretsOpts()]);

        $client->graphql('{ probe }');
        $this->assertCount(1, $wire->api());
        $this->assertCredential($wire->api()[0]['auth'], 'GQLKEY01');

        $brokenwire = new UnivecSecretsWire();
        $broken = $this->secretsClient($brokenwire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(function (string $_name) {
                    throw new \Voxgig\Sekreto\SekretoError('vault unreachable');
                })],
            ]],
        ]);

        $res = $broken->graphql('{ probe }');
        $this->assertFalse($res['ok'], 'a broken chain must refuse graphql fail-closed');
        $this->assertCount(0, $brokenwire->calls);
    }

    // -----------------------------------------------------------------
    // The access-token exchange.

    public function testTheRefreshTokenBuysAnAccessTokenAndASpentOneIsReboughtOnce(): void
    {
        $this->setenv('REFRESH_TOKEN', 'REFRESH01');
        $wire = new UnivecSecretsWire();
        // First API call is refused, the retry succeeds.
        $wire->apistatus = [401, 200];

        $client = $this->secretsClient($wire, [
            'feature' => $this->secretsOpts([
                'name' => 'refresh_token',
                'exchange' => ['active' => true],
            ]),
        ]);

        $this->driveOp($client, $wire);

        $this->assertCount(2, $wire->token(),
            'expected the initial purchase plus one rebuy');
        $this->assertStringContainsString('REFRESH01', (string)$wire->token()[0]['body']);

        $api = $wire->api();
        $this->assertCount(2, $api, 'expected the request to be retried exactly once');
        $this->assertCredential($api[0]['auth'], 'ACCESS01');
        // The retry must carry the NEW token, not the spent one.
        $this->assertCredential($api[1]['auth'], 'ACCESS02');
    }

    // `auth: null` SUPPRESSES THE PURCHASE, not just the retry.
    //
    // resolve() runs before with_refresh's suppression check, so the
    // refresh token used to go to the token endpoint in a request body even
    // here. Stopping the retry does not unsend it - this asserts on the
    // token endpoint, which is the half the API-header assertions cannot
    // see.
    public function testAuthNullBuysNoTokenAtAll(): void
    {
        $this->setenv('REFRESH_TOKEN', 'REFRESH01');
        $wire = new UnivecSecretsWire();
        $wire->apistatus = [401];

        $client = $this->secretsClient($wire, [
            'auth' => null,
            'feature' => $this->secretsOpts([
                'name' => 'refresh_token',
                'exchange' => ['active' => true],
            ]),
        ]);

        $this->driveOp($client, $wire);

        $this->assertCount(0, $wire->token(),
            'auth null suppressed the credential but the refresh token was ' .
            'still POSTed to the exchange endpoint');
        $this->assertFalse($wire->api()[0]['has'],
            'no credential may be sent when auth is suppressed');
    }

    // A second refusal on a token bought moments ago is a real failure, not
    // a spin: exactly one rebuy, and the refusal is returned as it stands.
    public function testASecondRefusalIsReturnedAsIs(): void
    {
        $this->setenv('REFRESH_TOKEN', 'REFRESH01');
        $wire = new UnivecSecretsWire();
        $wire->apistatus = [401];

        $client = $this->secretsClient($wire, [
            'feature' => $this->secretsOpts([
                'name' => 'refresh_token',
                'exchange' => ['active' => true],
            ]),
        ]);

        $this->driveOp($client, $wire);

        $this->assertCount(2, $wire->api(), 'one attempt plus one retry, no more');
        $this->assertCount(2, $wire->token());
    }

    // Test mode buys nothing and needs no token endpoint, so an offline
    // suite never makes the one HTTP call the test mock cannot stop.
    public function testTestModeBuysNothingAndNeedsNoTokenEndpoint(): void
    {
        $this->setenv('REFRESH_TOKEN', 'REFRESH01');
        $wire = new UnivecSecretsWire();

        $client = $this->withSecrets(function (bool $adopt) use ($wire) {
            $opts = [
                'system' => ['fetch' => $wire->fetch()],
                'feature' => $this->secretsOpts([
                    'name' => 'refresh_token',
                    'exchange' => ['active' => true],
                ]),
            ];
            if ($adopt) {
                $opts['extend'] = [new UnivecSecretsFeature()];
            }
            return UnivecSDK::test(null, $opts);
        });

        $this->driveUntil($client, 'resolved the fake token',
            fn() => '' !== $this->secretsFeatureOf($client)->credential());

        $this->assertCount(0, $wire->calls, 'test mode must not do IO');
        // A deterministic placeholder, so offline suites need no
        // configuration.
        $this->assertSame('test-access_token',
            $this->secretsFeatureOf($client)->credential());
    }

    // A failed PURCHASE answers with the API's own refusal, not the
    // exchange error: the caller asked for data, and the 401 is the more
    // useful of the two.
    public function testAFailedPurchaseAnswersWithTheApisOwnRefusal(): void
    {
        $this->clearenv('REFRESH_TOKEN');
        $wire = new UnivecSecretsWire();
        $wire->apistatus = [401];

        $client = $this->secretsClient($wire, [
            'apikey' => 'STALE01',
            'feature' => $this->secretsOpts([
                'name' => 'refresh_token',
                'exchange' => ['active' => true],
            ]),
        ]);

        $res = $client->direct(['path' => '/probe']);

        // 401 from the API, surfaced as the raw path's ok:false - not a
        // token exchange error.
        $this->assertFalse($res['ok']);
        $this->assertSame(401, $res['status']);
        $this->assertCount(1, $wire->api());
    }

    // The exchange with NO system.fetch: the raw fallback transport carries
    // the purchase end to end over REAL HTTP, and the body is ENCODED - a
    // refresh token full of JSON-hostile characters must arrive as that
    // literal value.
    // IN ITS OWN PROCESS, and this is the one lane that needs it. It is the
    // only test in the suite that reaches the SDK's DEFAULT transport (no
    // system.fetch anywhere - that is the point), and Fetcher::call decides
    // "no fetcher was supplied" by asking whether `system.fetch` is an empty
    // stdClass. The struct corpus suite that runs earlier in the same
    // process writes a property onto Struct's shared UNDEF sentinel - the
    // very object a missing path resolves to - so that check then answers
    // "not a valid function" for every default-transport request in the
    // process. A fresh process has a clean sentinel. See the followups: the
    // fix belongs in Struct::setprop, which must refuse to write to its own
    // sentinel, not here.
    #[\PHPUnit\Framework\Attributes\RunInSeparateProcess]
    #[\PHPUnit\Framework\Attributes\PreserveGlobalState(false)]
    public function testTheExchangeWorksWithOrdinaryOptionsAndEncodesItsBody(): void
    {
        $tricky = "re\"fresh\\to\nken";

        $stub = new UnivecSecretsHttpStub();
        $port = $stub->start();
        if (0 === $port) {
            $this->markTestSkipped('could not start the local HTTP stub');
        }

        try {
            $client = $this->withSecrets(function (bool $adopt) use ($port, $tricky) {
                $opts = [
                    'base' => 'http://127.0.0.1:' . $port . '/api',
                    'feature' => ['secrets' => [
                        'active' => true,
                        'name' => 'refresh_token',
                        'exchange' => ['active' => true, 'refresh' => $tricky],
                    ]],
                ];
                if ($adopt) {
                    $opts['extend'] = [new UnivecSecretsFeature()];
                }
                return new UnivecSDK($opts);
            });

            // No system.fetch anywhere: the API call takes the SDK's default
            // transport and the token purchase takes the feature's raw
            // fallback.
            $res = $client->direct(['path' => '/probe']);
            $this->assertTrue($res['ok'], 'the raw fallback exchange failed');
        } finally {
            $stub->stop();
        }

        $this->assertSame($tricky, $stub->refresh(),
            'the refresh token must arrive as its literal value (encoded, not concatenated)');
        $this->assertCredential($stub->auth(), 'RAWTOK01');

        // stop() must leave NOTHING behind. This is asserted, not assumed:
        // a child spawned through a shell survives proc_terminate as an
        // orphan that holds the port for the rest of the machine's life -
        // and, because it inherits the run's own descriptors, holds a
        // captured pipe open so that `make test | tee` (or any CI log
        // capture) never returns. The temp directory is the second trace,
        // one per run.
        $leak = $stub->leak();
        $this->assertNull($leak, 'the stub outlived stop(): ' . (string)$leak);
    }

    // -----------------------------------------------------------------
    // The refusal is NOT retried. The gate lives at the transport, so a
    // provider ERROR must fail the operation once - never spin the chain,
    // and never let a later attempt through unauthenticated.
    public function testAProviderErrorIsRefusedOnceAndNotRetried(): void
    {
        $calls = 0;
        $wire = new UnivecSecretsWire();
        $client = $this->secretsClient($wire, [
            'feature' => ['secrets' => [
                'active' => true,
                'providers' => [$this->customProvider(
                    function (string $_name) use (&$calls) {
                        $calls++;
                        throw new \Voxgig\Sekreto\SekretoError('vault unreachable');
                    })],
            ]],
        ]);

        $accessor = $this->entityAccessors($client)[0] ?? null;
        $this->assertNotNull($accessor);

        try {
            $client->$accessor()->list();
            $this->fail('the op must fail closed');
        } catch (UnivecError $e) {
            // expected
        }

        $this->assertSame(1, $calls, 'the refusal must not be retried');
        $this->assertCount(0, $wire->calls);
    }
}

// A one-request-at-a-time HTTP stand-in, run as a child `php -S` process:
// the raw-fallback exchange has to be exercised over REAL HTTP (that is the
// whole point of the lane), and PHP has no threads to serve it in-process.
// Answers the token endpoint with an access token and every other path with
// an empty JSON body, recording what each request carried.
class UnivecSecretsHttpStub
{
    private mixed $proc = null;
    private string $dir = '';
    private int $port = 0;

    // What the server recorded, READ OFF DISK BY stop() before the temp
    // directory goes: the assertions run after the `finally`, and a stub
    // that cleans up after itself has no files left to answer from.
    private ?string $refresh = null;
    private ?string $auth = null;

    public function start(): int
    {
        $this->dir = sys_get_temp_dir() . '/secrets-stub-' . bin2hex(random_bytes(6));
        if (!@mkdir($this->dir, 0700, true)) {
            $this->dir = '';
            return 0;
        }

        $router = <<<'ROUTER'
<?php
$dir = __DIR__;
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?? '/';
if (str_ends_with($path, '/auth/token')) {
    $raw = file_get_contents('php://input');
    $parsed = json_decode((string)$raw, true);
    file_put_contents($dir . '/refresh.txt',
        is_array($parsed) ? (string)($parsed['refresh_token'] ?? '') : '');
    header('content-type: application/json');
    echo '{"access_token": "RAWTOK01"}';
    return;
}
$auth = '';
foreach ($_SERVER as $k => $v) {
    if ('HTTP_AUTHORIZATION' === $k) { $auth = (string)$v; }
}
file_put_contents($dir . '/auth.txt', $auth);
header('content-type: application/json');
echo '{}';
ROUTER;
        file_put_contents($this->dir . '/router.php', $router);

        // A free port: bind, read it, release it. The window between release
        // and the server's own bind is the usual small race, and a failure
        // to come up skips the test rather than failing it.
        $probe = @stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
        if (false === $probe) {
            $this->stop();
            return 0;
        }
        $name = stream_socket_get_name($probe, false);
        fclose($probe);
        $port = (int)substr((string)$name, (int)strrpos((string)$name, ':') + 1);
        if (0 === $port) {
            $this->stop();
            return 0;
        }

        // An ARRAY command, never a string. proc_open runs a STRING through
        // `/bin/sh -c`, and the process it then hands back is the SHELL:
        // proc_terminate would signal that, leaving `php -S` alive as an
        // orphan holding the port - and, under `make test | tee` or any CI
        // log capture, holding the pipe open so the run never ends. The
        // array form execs the binary directly, so the child this object
        // holds IS the server.
        $cmd = [PHP_BINARY, '-S', '127.0.0.1:' . $port, $this->dir . '/router.php'];
        // Every child descriptor is a FILE, never a pipe: a pipe end the
        // parent never drains is a stall waiting to happen, and a test
        // harness that captures output must not end up waiting on the
        // server's.
        $pipes = [];
        $this->proc = @proc_open($cmd, [
            0 => ['file', '/dev/null', 'r'],
            1 => ['file', $this->dir . '/out.log', 'a'],
            2 => ['file', $this->dir . '/err.log', 'a'],
        ], $pipes, $this->dir);

        if (!is_resource($this->proc)) {
            $this->stop();
            return 0;
        }

        for ($i = 0; $i < 100; $i++) {
            $sock = @stream_socket_client('tcp://127.0.0.1:' . $port, $e1, $e2, 0.2);
            if (false !== $sock) {
                fclose($sock);
                $this->port = $port;
                return $port;
            }
            usleep(50000);
        }

        $this->stop();
        return 0;
    }

    // Stop the server and leave NOTHING behind - no process, no directory.
    // Called from the test's `finally` and from every failure path in
    // start(), which markTestSkipped() unwinds past before any `finally`
    // exists.
    public function stop(): void
    {
        // Read the recording out first: the files are about to go.
        $this->refresh = $this->slurp('refresh.txt') ?? $this->refresh;
        $this->auth = $this->slurp('auth.txt') ?? $this->auth;

        if (is_resource($this->proc)) {
            proc_terminate($this->proc);
            // proc_close REAPS the child, so the process is gone (not a
            // zombie) by the time this returns.
            proc_close($this->proc);
            $this->proc = null;
        }

        if ('' !== $this->dir) {
            foreach ((array)@scandir($this->dir) as $f) {
                if ('.' !== $f && '..' !== $f) {
                    @unlink($this->dir . '/' . $f);
                }
            }
            @rmdir($this->dir);
        }
    }

    // Did stop() actually stop it? The two observable traces a leak leaves:
    // the port still answering (an orphaned server), and the temp directory
    // still on disk. Asserted by the test, so a stub that goes back to
    // leaking fails the suite instead of quietly filling /tmp and hanging
    // every piped run.
    public function leak(): ?string
    {
        if ('' !== $this->dir && is_dir($this->dir)) {
            return 'temp directory still on disk: ' . $this->dir;
        }

        if (0 === $this->port) {
            return null;
        }

        // The listener can take a moment to go after SIGTERM; a still-open
        // port after that is an orphan, not a race.
        for ($i = 0; $i < 40; $i++) {
            $sock = @stream_socket_client('tcp://127.0.0.1:' . $this->port, $e1, $e2, 0.2);
            if (false === $sock) {
                return null;
            }
            fclose($sock);
            usleep(50000);
        }

        return 'a server is still listening on 127.0.0.1:' . $this->port;
    }

    public function refresh(): ?string
    {
        return $this->slurp('refresh.txt') ?? $this->refresh;
    }

    public function auth(): ?string
    {
        return $this->slurp('auth.txt') ?? $this->auth;
    }

    private function slurp(string $file): ?string
    {
        if ('' === $this->dir) {
            return null;
        }
        $out = @file_get_contents($this->dir . '/' . $file);
        return false === $out ? null : $out;
    }
}
