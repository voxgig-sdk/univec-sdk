<?php
declare(strict_types=1);

// Univec SDK secrets feature

require_once __DIR__ . '/BaseFeature.php';
require_once __DIR__ . '/../utility/Fetcher.php';
require_once __DIR__ . '/secrets/sekreto/src/Sekreto.php';

// A custom provider given as a MAP of callables, adapted to the object
// shape sekreto's chain reads.
//
// ts accepts `{ lookup() {...}, describe() {...} }` verbatim because a JS
// object literal survives the options clone with its functions intact.
// PHP's `Struct::clone` flattens a class INSTANCE to a stdClass (methods
// lost) while CLOSURES survive, so the array-of-callables IS the shape that
// reaches this feature - the exact parallel of the ts contract, and the
// same adaptation py's `_LiveProvider` makes for the same reason.
//
// php's Provider is a NOMINAL interface, unlike go's structural one, so a
// provider written as a real class must `implements \Voxgig\Sekreto\Provider`
// and be handed in a way the clone cannot flatten (sekreto's own
// ProviderSpec array is the portable route).
class UnivecSecretsMapProvider implements \Voxgig\Sekreto\Provider
{
    /** @var array<string,mixed> */
    private array $spec;

    /** @param array<string,mixed> $spec */
    public function __construct(array $spec)
    {
        $this->spec = $spec;
    }

    public function lookup(string $name): ?string
    {
        // MISS vs ERROR is the caller's to signal: anything but a string is
        // a miss, and a THROW propagates as the provider error it is.
        $found = ($this->spec['lookup'])($name);
        return is_string($found) ? $found : null;
    }

    public function describe(): string
    {
        $describe = $this->spec['describe'] ?? null;
        if (is_callable($describe)) {
            $out = $describe();
            return is_string($out) ? $out : 'custom';
        }
        return 'custom';
    }
}

// Secret access via a vendored @voxgig/sekreto provider chain, and the
// access-token exchange some APIs require on top of it. The php port of
// tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, php idiom,
// and structurally go's (tm/go/feature/secrets_feature.go), for the reason
// spelled out under RESOLUTION LIVES AT THE TRANSPORT below.
//
// The SDK's `apikey` option keeps exactly its old meaning: an explicit
// credential given in code. This feature makes it ONE SOURCE among several
// rather than the only one: when active, the apikey is resolved through a
// sekreto chain in which the explicit option (when set) is the FIRST
// provider - a `memory` store named 'options' - so an explicit value always
// wins, by sekreto's own first-hit rule rather than by special-case logic.
// When the option is unset, the remaining providers (env, dotenv, a vault)
// are asked in order, and moving a credential from code to a vault becomes
// a configuration change.
//
// RESOLUTION LIVES AT THE TRANSPORT, not in the PreSpec hook. `direct()`
// and `graphql()` reach the wire through UnivecSDK::raw_request, which
// runs NO feature hooks at all - its own comment says so - so a hook-only
// design would leave the raw paths silently unauthenticated, and would have
// no way to refuse them when the chain is broken. The transport is the ONE
// seam every wire path crosses (utility/MakeRequest.php and Main's
// raw_request both call `$utility->fetcher`), so the wrapper installed in
// init() resolves there, rewrites the authorization header prepare_auth
// built, and refuses the request outright when a provider errors.
//
// MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
// op proceeds, unauthenticated if nothing else supplies a credential. A
// provider ERROR (unreachable vault, bad credentials) must FAIL the op: a
// broken vault never degrades into an unauthenticated request. The wrapper
// answers `[null, $ctx->make_error('secrets_provider', ...)]`, which the
// entity pipeline turns into a thrown UnivecError and the raw paths
// report as `['ok' => false, 'err' => ...]`.
//
// EXCHANGE: some APIs will not take a long-lived credential at all. What
// the chain resolves is then a REFRESH token, which buys a short-lived
// ACCESS token from a token endpoint (`exchange.path`, relative to
// options.base); the access token is what every request carries, and when a
// response status in `exchange.statuses` (401) says it is spent the wrapper
// buys another and retries the same request once. Test mode buys nothing
// and answers with a deterministic fake token.
class UnivecSecretsFeature extends UnivecBaseFeature
{
    private mixed $client = null;

    /** @var array<string,mixed> */
    private array $options = [];

    // The processed options as they stood at construction, for the values
    // that cannot change afterwards: `auth` (including a suppressing null)
    // and a starting access token. Held rather than re-cloned per request -
    // options_map() is a deep clone, and this runs on every send.
    /** @var array<string,mixed> */
    private array $liveopts = [];

    private string $secretname = 'apikey';
    private bool $cache = true;
    private ?\Voxgig\Sekreto\Sekreto $sekreto = null;
    private ?\Throwable $initerr = null;

    // Exchange state: null config when off, so every later decision is a
    // null check; `$refresh` is the credential the chain resolved.
    private ?array $exchange = null;
    private ?string $refresh = null;

    // The RESOLVED credential, held in FEATURE STATE and injected into each
    // request at the transport seam - NEVER written into the client's
    // options map. That is go's construction (secrets_feature.go `cred`)
    // and the one this port follows.
    //
    // Publishing it to `$client->options` was tried and REMOVED. It cannot
    // deliver what it promises: resolution only ever happens when a request
    // crosses the transport, so a fresh client's `prepare(...)` is
    // unauthenticated anyway, and a BROKEN chain publishes nothing at all -
    // `prepare(...)` then hands back a request with no credential AND no
    // error, the silent authenticate-as-nobody shape this feature exists to
    // prevent. What it does deliver is the cost: the vault secret parked in
    // a map every consumer can read and `options_map()` hands out, even
    // when `auth: null` says no credential may be sent at all.
    //
    // So `prepare(...)` reflects the OPTIONS, as it always has: an explicit
    // `apikey` shows up there, a chain-resolved one does not. Everything
    // the SDK itself sends - entity ops, direct, graphql, exchange retries -
    // crosses the transport and carries the credential.
    private string $cred = '';
    private bool $resolved = false;

    public function __construct()
    {
        parent::__construct();
        $this->version = '0.1.0';
        $this->name = 'secrets';
        // Inactive until init (feature_init only fires init when active).
        $this->active = false;
    }

    // Sync by feature contract: build the chain, never look anything up
    // here.
    public function init(UnivecContext $ctx, array $options): void
    {
        $this->client = $ctx->client;
        $this->options = $options;
        $this->liveopts = is_array($ctx->options) ? $ctx->options : [];
        $this->active = ($options['active'] ?? null) === true;

        if (!$this->active) {
            return;
        }

        $name = $options['name'] ?? null;
        $this->secretname = (is_string($name) && '' !== $name) ? $name : 'apikey';
        $this->cache = ($options['cache'] ?? null) !== false;

        $xopts = is_array($options['exchange'] ?? null) ? $options['exchange'] : [];

        // Exchange config, normalised once.
        if (($xopts['active'] ?? null) === true) {
            $statuses = [];
            if (is_array($xopts['statuses'] ?? null)) {
                foreach ($xopts['statuses'] as $s) {
                    if (is_numeric($s)) {
                        $statuses[] = (int)$s;
                    }
                }
            }
            if (0 === count($statuses)) {
                $statuses = [401];
            }
            $this->exchange = [
                'path' => self::str($xopts['path'] ?? null, 'auth/token'),
                'method' => self::str($xopts['method'] ?? null, 'POST'),
                'request' => self::str($xopts['request'] ?? null, 'refresh_token'),
                'response' => self::str($xopts['response'] ?? null, 'access_token'),
                'statuses' => $statuses,
                'retries' => is_numeric($xopts['retries'] ?? null) ? (int)$xopts['retries'] : 1,
            ];
        }

        // The explicit credential, when set, is the first store in the
        // chain.
        //
        // WHICH option that is depends on the exchange. Without one, the
        // secret being resolved IS the credential the transport sends, so
        // `apikey` is it. With one, the secret is a REFRESH token and
        // `apikey` means the opposite thing - an access token the caller
        // already holds - so the explicit seat belongs to
        // `exchange.refresh`, and apikey is left alone to serve as the
        // starting access token (see resolve_once).
        $explicit = null === $this->exchange
            ? ($this->liveopts['apikey'] ?? null)
            : ($xopts['refresh'] ?? null);

        try {
            $specs = [];

            if (is_string($explicit) && '' !== $explicit) {
                $specs[] = [
                    'kind' => 'memory',
                    'name' => 'options',
                    'values' => [
                        \Voxgig\Sekreto\Name::envkey($this->secretname) => $explicit,
                    ],
                ];
            }

            $providers = $options['providers'] ?? null;
            if (is_array($providers)) {
                foreach ($providers as $p) {
                    $specs[] = self::provider_entry($p);
                }
            }

            $this->sekreto = new \Voxgig\Sekreto\Sekreto([
                'providers' => $specs,
                'plugins' => $this->plugins(),
                'cache' => $this->cache,
            ]);
        } catch (\Throwable $e) {
            // A misconfigured chain must not degrade into unauthenticated
            // requests: remember the failure and let the transport gate
            // below refuse every send. (init cannot throw - the constructor
            // would take the whole client down for a fault the caller can
            // only see at request time anyway.)
            $this->initerr = $e;
            $this->sekreto = null;
        }

        // Seam for callers wanting the live Sekreto without walking
        // $sdk->features.
        $ctx->client->_secrets = $this;

        // Wrap the transport UNCONDITIONALLY while active - including after
        // an init failure, which is exactly when the gate matters most. The
        // exchange additionally needs to SEE responses (a spent token is
        // only ever discovered from one), and this is the one place a
        // response can be seen and the request tried again.
        $utility = $ctx->utility;
        $inner = $utility->fetcher;

        $utility->fetcher = function (UnivecContext $ctx2, string $url, array $fetchdef) use ($inner): array {
            return $this->transport($ctx2, $url, $fetchdef, $inner);
        };
    }

    // The LIVE Sekreto instance, for callers who want arbitrary secrets or
    // redaction:
    //
    //   $sdk->_secrets->sekreto()->get('db.password')
    //   $sdk->_secrets->sekreto()->redact($logline)
    //
    // Never a clone: sekreto holds provider state (caches, vault leases)
    // that has to stay live to be worth anything.
    public function sekreto(): ?\Voxgig\Sekreto\Sekreto
    {
        return $this->sekreto;
    }

    // The resolved credential (empty when none) - the state the transport
    // injects. Tests and callers read it here rather than inferring it.
    public function credential(): string
    {
        return $this->cred;
    }

    // transport wraps whatever transport was current at init.
    public function transport(UnivecContext $ctx, string $url, array $fetchdef, mixed $inner): array
    {
        // Fail-closed, at the ONE seam every wire path crosses. Entity ops,
        // direct, graphql and the exchange retries all come through here,
        // so resolving HERE is what gives the raw paths - which run no
        // feature hooks at all - the same credential the entity pipeline
        // gets. A provider ERROR refuses the request with the provider's
        // own message; never an unauthenticated send.
        $err = $this->resolve();
        if (null !== $err) {
            return [null, $ctx->make_error('secrets_provider', $err->getMessage())];
        }

        // Inject the resolved credential into THIS request's header, the
        // way prepare_auth built it, from the same options auth.prefix so
        // the two cannot drift. An EMPTY credential removes the header:
        // with the feature active the chain is the authority, and an
        // uncached miss after an earlier hit (a revoked secret) must stop
        // transmitting the value the previous hit put there.
        $this->inject($fetchdef, $this->cred);

        if (null === $this->exchange) {
            return $inner($ctx, $url, $fetchdef);
        }

        return $this->with_refresh($ctx, $url, $fetchdef, $inner);
    }

    // One resolution, reused by every later request while caching is on
    // (`cache: false` means every request asks the chain again). A FAILURE
    // is never cached, so a transient vault outage does not poison the
    // client after the vault recovers.
    //
    // A MISS is not cached either, however caching is set. That rule is
    // sekreto's, not this feature's: `A miss is never cached: the next read
    // asks again`, in sekreto's own source. Caching a settled miss here
    // would override that from the layer above, and a secret provisioned
    // after startup - a mounted file, a policy granted a minute late -
    // would never be picked up for the life of the client. `cache` is about
    // caching a HIT; it was never a promise to keep saying no.
    //
    // Answers the error rather than throwing it: the caller is the
    // transport gate, whose contract is a [value, err] pair.
    public function resolve(): ?\Throwable
    {
        if (null !== $this->initerr) {
            return $this->initerr;
        }
        if ($this->resolved) {
            return null;
        }

        try {
            $hit = $this->resolve_once();
        } catch (\Throwable $e) {
            return $e;
        }

        if ($this->cache && $hit) {
            $this->resolved = true;
        }

        return null;
    }

    // Resolve once, answering whether a credential came out of it. That
    // bool is the whole of what resolve() needs to tell a cacheable HIT
    // from a miss it must not cache.
    private function resolve_once(): bool
    {
        if (null === $this->sekreto) {
            return false;
        }

        // Miss-vs-error: `try` answers null for "no store has it" and
        // THROWS for "a store could not answer" - only the miss falls
        // through.
        $found = $this->sekreto->try($this->secretname);
        if (!is_string($found)) {
            $found = null;
        }

        if (null === $this->exchange) {
            // An UNCACHED miss after an earlier hit is a revocation: the
            // chain now says no provider has the secret, so the resolved
            // value must not keep going out on the wire. (An explicit
            // apikey OPTION is never lost here - it seats FIRST in the
            // chain as a memory provider, so the chain HITS while one is
            // set and the miss branch is unreachable.)
            $this->setcred($found);
            return null !== $found;
        }

        // Exchanging: what the chain resolved is the REFRESH token, kept
        // for every later purchase. A miss is not fatal here - an explicit
        // `apikey` may already hold a usable access token, and the API is
        // what gets to say whether it does.
        $this->refresh = $found;

        $apikey = $this->cred;
        if ('' === $apikey) {
            $starting = $this->liveopts['apikey'] ?? null;
            $apikey = is_string($starting) ? $starting : '';
            if ('' !== $apikey) {
                $this->setcred($apikey);
            }
        }

        if ('' !== $apikey) {
            // A starting access token was supplied. Spend it: if it is
            // stale the API answers with an expiry status and the wrapper
            // buys another, which is the same path expiry takes anyway.
            return true;
        }

        // `auth: null` is the documented way to send NO credential, and a
        // purchase is a credential-bearing call: the refresh token goes to
        // the token endpoint in the request body. with_refresh honours
        // suppression for the RETRY, but it runs after this - by then the
        // refresh token has already left the process, and no later check
        // can call it back. The suppression has to be honoured here, before
        // the first purchase, or it only ever half-held.
        if (null === ($this->liveopts['auth'] ?? null)) {
            return false;
        }

        $this->buy();

        return true;
    }

    // Buy a token and try the request again when the API says the current
    // one is spent.
    //
    // The retry rewrites the authorization header IN PLACE on the fetchdef,
    // because the header was built by the synchronous prepare_auth before
    // this request left, and it carries the token that just failed.
    private function with_refresh(UnivecContext $ctx, string $url, array $fetchdef, mixed $inner): array
    {
        // `auth: null` is the documented way to send NO credential, and
        // prepare_auth honours it by removing the header. A refusal of a
        // deliberately unauthenticated request is not an expired token and
        // cannot be fixed by buying one - retrying would transmit exactly
        // the credential the caller suppressed.
        if (null === ($this->liveopts['auth'] ?? null)) {
            return $inner($ctx, $url, $fetchdef);
        }

        $max = $this->exchange['retries'];
        $attempt = 0;

        while (true) {
            // The credential THIS attempt goes out with, captured before it
            // leaves: it is what tells a stale refusal apart from a fresh
            // one.
            $used = $this->cred;

            [$res, $err] = $inner($ctx, $url, $fetchdef);

            if (null !== $err || $attempt >= $max || !$this->spent($res)) {
                return [$res, $err];
            }

            // Another request may have bought a token while this one was in
            // flight. Spend what is current before buying: a second
            // exchange for a token that is already fresh is wasted, and on
            // a provider that invalidates the previous credential on
            // issuance it breaks the first request's own retry.
            $current = $this->cred;

            if ('' !== $current && $current !== $used) {
                $token = $current;
            } else {
                try {
                    $token = $this->buy();
                } catch (\Throwable $e) {
                    // The purchase failed: answer with the API's own
                    // refusal rather than this one. The caller asked for
                    // data, and the 401 is the more useful of the two - the
                    // exchange error is a symptom.
                    return [$res, $err];
                }
            }

            $this->inject($fetchdef, $token);

            $attempt++;
        }
    }

    private function spent(mixed $res): bool
    {
        if (!is_array($res)) {
            return false;
        }
        $status = $res['status'] ?? null;
        if (!is_numeric($status)) {
            return false;
        }
        return in_array((int)$status, $this->exchange['statuses'], true);
    }

    // Buy an access token with the refresh token.
    private function buy(): string
    {
        // TEST MODE BUYS NOTHING.
        //
        // The test feature replaces the transport so that no request leaves
        // the process; an exchange here would be the one HTTP call it could
        // not stop, and it would need a live token endpoint for a suite
        // whose whole point is not needing one. A deterministic,
        // obviously-fake token instead - the same answer make_options gives
        // a required server variable, for the same reason.
        if ('live' !== $this->client->mode) {
            $token = 'test-' . $this->exchange['response'];
            $this->setcred($token);
            return $token;
        }

        $token = $this->buy_once();
        $this->setcred($token);
        return $token;
    }

    private function buy_once(): string
    {
        $x = $this->exchange;

        if (null === $this->refresh || '' === $this->refresh) {
            throw new \Voxgig\Sekreto\SekretoError(
                "secrets: no refresh token: the provider chain has no '" .
                $this->secretname . "', and feature.secrets.exchange.refresh is unset");
        }

        $options = $this->client->options_map();

        // The token endpoint is RELATIVE to the base, which already carries
        // whatever account or tenant segment the server URL declares.
        $base = $options['base'] ?? '';
        $base = is_string($base) ? rtrim($base, '/') : '';
        $url = $base . '/' . ltrim($x['path'], '/');

        $fetch = \Voxgig\Struct\Struct::getpath($options, 'system.fetch');

        if (!is_callable($fetch)) {
            // No custom transport supplied - the ordinary case.
            // make_options leaves system.fetch unset, so the exchange gets
            // the SDK's own default HTTP path. That static consults neither
            // system.fetch nor the wrapper chain, so there is no recursion,
            // and it already answers the ['status' => .., 'json' => ..]
            // shape read below.
            $fetch = [UnivecFetcher::class, 'defaultHttpFetch'];
        }

        // The body is ENCODED, never concatenated: a refresh token (or a
        // configured request-field name) carrying a quote, backslash or
        // newline must arrive as that literal value, not as malformed JSON.
        $body = json_encode([$x['request'] => $this->refresh]);
        if (false === $body) {
            throw new \Voxgig\Sekreto\SekretoError(
                'secrets: token exchange request could not be encoded');
        }

        // Deliberately NOT the SDK transport. The transport is what this
        // feature wraps, and sending the token request back through it
        // would recurse on the first expiry - and would route the exchange
        // through the test mock, which knows nothing about it.
        [$res, $err] = $fetch($url, [
            'method' => $x['method'],
            'headers' => ['content-type' => 'application/json'],
            'body' => $body,
        ]);

        if (null !== $err) {
            throw new \Voxgig\Sekreto\SekretoError(
                'secrets: token exchange failed: ' . self::errtext($err) . ' from ' . $url);
        }

        $status = is_array($res) && is_numeric($res['status'] ?? null) ? (int)$res['status'] : 0;

        if (200 > $status || 300 <= $status) {
            throw new \Voxgig\Sekreto\SekretoError(
                'secrets: token exchange failed: ' . $status . ' from ' . $url);
        }

        $jf = is_array($res) ? ($res['json'] ?? null) : null;
        $payload = is_callable($jf) ? $jf() : (is_array($res) ? ($res['body'] ?? null) : null);

        if (is_string($payload)) {
            $decoded = json_decode($payload, true);
            $payload = JSON_ERROR_NONE === json_last_error() ? $decoded : null;
        }
        if (is_object($payload)) {
            $payload = (array)$payload;
        }

        $token = is_array($payload) ? ($payload[$x['response']] ?? null) : null;

        if (!is_string($token) || '' === $token) {
            throw new \Voxgig\Sekreto\SekretoError(
                "secrets: token exchange returned no '" . $x['response'] .
                "' field from " . $url);
        }

        return $token;
    }

    // The resolved credential goes to FEATURE STATE and nowhere else - see
    // `$cred` above for why the client's options map is not a second home
    // for it. An empty value RETRACTS: the transport reads this on every
    // send, so a revoked secret stops going out on the next request.
    private function setcred(?string $value): void
    {
        $this->cred = is_string($value) ? $value : '';
    }

    // Rebuild the authorization header from the credential, exactly as
    // prepare_auth builds it.
    private function inject(array &$fetchdef, string $token): void
    {
        if (!is_array($fetchdef['headers'] ?? null)) {
            return;
        }

        // Suppressed auth means NO header, the same answer prepare_auth
        // gives - and so does an empty credential.
        if (null === ($this->liveopts['auth'] ?? null) || '' === $token) {
            unset($fetchdef['headers']['authorization']);
            return;
        }

        $prefix = \Voxgig\Struct\Struct::getpath($this->liveopts, 'auth.prefix');
        if (!is_string($prefix)) {
            $prefix = '';
        }

        // Empty prefix (raw apiKey credential) must not add a leading space.
        $fetchdef['headers']['authorization'] = '' === $prefix
            ? $token : $prefix . ' ' . $token;
    }

    // One chain entry as sekreto will take it: a ProviderSpec array (it has
    // a `kind`) passes straight through, and an array carrying a `lookup`
    // CLOSURE becomes a live provider (see UnivecSecretsMapProvider).
    //
    // `instanceof \Closure` rather than is_callable, deliberately. A closure
    // is the only callable form that survives `Struct::clone` intact - an
    // array callable's object half is flattened to a stdClass - so anything
    // else here is a value that could not work, and is_callable would ALSO
    // say yes to the plain string 'strlen', turning a ProviderSpec field
    // that happened to name a function into a bogus live provider. Every
    // useful spelling (`function () {}`, `fn () =>`, `$obj->m(...)`,
    // `Cls::m(...)`) is a Closure.
    private static function provider_entry(mixed $p): mixed
    {
        if (is_array($p)) {
            if (($p['lookup'] ?? null) instanceof \Closure) {
                return new UnivecSecretsMapProvider($p);
            }

            // An array with no `kind` is what a provider CLASS INSTANCE
            // becomes by the time it gets here: make_options clones the
            // options and then flattens every object to its public
            // properties, so the methods are already gone. sekreto would
            // call that "unknown provider kind: " - the symptom, not the
            // cause. Say what actually happened and what to pass instead.
            //
            // The throw lands in init's catch, which leaves the chain
            // broken, so every request fails CLOSED rather than going out
            // unauthenticated on a chain the caller thinks is live.
            if (!isset($p['kind'])) {
                throw new \Voxgig\Sekreto\SekretoError(
                    "secrets: a provider entry has no 'kind'. A provider " .
                    'OBJECT cannot reach this feature - the client option ' .
                    'clone flattens any class instance to its public ' .
                    'properties and its methods are lost. Pass a ' .
                    "ProviderSpec array (['kind' => 'env', ...]) or an " .
                    "array of closures (['lookup' => fn (string \$name) " .
                    "=> ..., 'describe' => fn () => ...]).");
            }
        }

        return $p;
    }

    // The plugin DEFINITIONS the model selected for this feature, emitted
    // by Config generically from the catalogue's active `plugin.def`
    // entries. Upstream sekreto's contract since the registry was retired:
    // a kind not passed in `plugins` is unknown to this Sekreto, so the
    // model's choice of plugin groups IS the SDK's provider vocabulary.
    //
    // Read through method_exists: the accessor is emitted only when the
    // model declares a plugin catalogue, so an SDK whose chain is all
    // built-ins carries no plugin code at all.
    private function plugins(): array
    {
        if (!method_exists('UnivecConfig', 'feature_plugins')) {
            return [];
        }
        $plugs = UnivecConfig::feature_plugins($this->name);
        return is_array($plugs) ? $plugs : [];
    }

    private static function str(mixed $value, string $dflt): string
    {
        return (is_string($value) && '' !== $value) ? $value : $dflt;
    }

    private static function errtext(mixed $err): string
    {
        if ($err instanceof \Throwable) {
            return $err->getMessage();
        }
        return is_string($err) ? $err : gettype($err);
    }
}
