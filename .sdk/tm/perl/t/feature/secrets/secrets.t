#!perl
# Univec SDK secrets feature test
#
# Behavioural tests for the secrets feature (vendored @voxgig/sekreto).
#
# The contract under test: the `apikey` OPTION keeps its exact old meaning
# and always wins, because the feature places it FIRST in the provider
# chain (a `memory` store named `options`) - explicit-beats-lookup falls
# out of sekreto's first-hit rule rather than from special-case logic.
# With the feature inactive nothing changes at all. With it active and the
# option unset, the chain (env, dotenv, a custom provider, a vault)
# supplies the credential instead.
#
# EVERY ASSERTION IS MADE ON THE WIRE, not on the harness.
#
# This port resolves at the TRANSPORT SEAM (feature/secrets_feature.pm),
# so the credential is not visible in prepare()'s fetchdef and there is no
# useful in-process proxy for "a request went out". Each client below is
# therefore a LIVE one whose `system.fetch` is the counter - the real
# transport the SDK reaches through utility/fetcher.pm - and never
# UnivecSDK->test, whose test feature REPLACES that transport with an
# in-memory mock. Under the mock, "no request was sent" holds for a
# healthy SDK carrying no secrets feature at all, so the assertion would
# pin nothing.
#
# For the same reason every fail-closed case carries a CONTROL leg: the
# same construction with a WORKING provider must reach the same transport
# exactly once, carrying the credential. Only then does a zero from the
# broken provider mean REFUSED rather than UNWIRED.
#
# This file lives in a `feature/` container on purpose: `target add` trims
# it, along with the feature source and the vendored library, for a
# project whose model does not select `secrets`.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Scalar::Util ();

use UnivecSDK;

my $ENVPREFIX = 'PROJECTENV_TEST_SECRETS_';

my $RAWBASE = 'http://raw.test/api';
my $XBASE = 'http://exchange.test/api';


# --- Harness ---------------------------------------------------------------

# A transport that records every call it is handed, so "sent" is a fact
# about the wire rather than about a mock. Same ($res, $err) tuple shape
# utility/fetcher.pm's own transports return.
#
# `apistatus` is a SCRIPT - one status per API call, the last repeating -
# so a case can say "401 then 200" without counting calls itself.
sub counting_fetch {
  my (%opt) = @_;
  my $tokenpath = defined $opt{path} ? $opt{path} : 'auth/token';
  my $respfield = defined $opt{response} ? $opt{response} : 'access_token';
  my @tokens = @{ $opt{tokens} || ['ACCESS01', 'ACCESS02', 'ACCESS03'] };
  my @apistatus = @{ $opt{apistatus} || [200] };

  my $stub = { sent => 0, calls => [], issued => 0, apicall => -1 };

  $stub->{istoken} = sub {
    my ($url) = @_;
    return ($url =~ m{/\Q$tokenpath\E\z}) ? 1 : 0;
  };

  $stub->{fetch} = sub {
    my ($url, $fetchdef) = @_;
    $fetchdef = {} unless defined $fetchdef;
    my $headers = $fetchdef->{headers} || {};

    $stub->{sent}++;
    push @{ $stub->{calls} }, {
      'url' => $url,
      'method' => $fetchdef->{method},
      'body' => $fetchdef->{body},
      'auth' => $headers->{'authorization'},
    };

    if ($stub->{istoken}->($url)) {
      return ({
        'status' => 401, 'statusText' => 'ERR', 'headers' => {},
        'json' => sub { { 'error' => 'nope' } }, 'body' => '{}',
      }, undef) if $opt{tokenfails};

      my $i = $stub->{issued};
      $i = $#tokens if $i > $#tokens;
      $stub->{issued}++;
      my $body = { $respfield => $tokens[$i] };
      return ({
        'status' => 200, 'statusText' => 'OK', 'headers' => {},
        'json' => sub { $body }, 'body' => '{}',
      }, undef);
    }

    $stub->{apicall}++;
    my $ai = $stub->{apicall};
    $ai = $#apistatus if $ai > $#apistatus;
    my $status = $apistatus[$ai];
    return ({
      'status' => $status, 'statusText' => ($status < 400 ? 'OK' : 'ERR'),
      'headers' => {},
      'json' => sub { { 'ok' => ($status < 400 ? 1 : 0) } },
      'body' => '{}',
    }, undef);
  };

  return $stub;
}


# Only the calls that went to the API, and only those that went to the
# token endpoint.
sub api_calls {
  my ($stub) = @_;
  return [grep { !$stub->{istoken}->($_->{url}) } @{ $stub->{calls} }];
}

sub token_calls {
  my ($stub) = @_;
  return [grep { $stub->{istoken}->($_->{url}) } @{ $stub->{calls} }];
}


# What went out, for a failure message that names the leak rather than
# just its count.
sub wire {
  my ($stub) = @_;
  return join(', ', map {
    $_->{url} . ' auth=' . (defined $_->{auth} ? $_->{auth} : '(none)')
  } @{ $stub->{calls} });
}


# The Authorization header carries the SPEC's credential prefix, which a
# TEMPLATE cannot know: an OpenAPI `http`/`bearer` scheme gives
# `Bearer <token>`, an apiKey scheme the raw token. So assert on the
# CREDENTIAL and let the prefix be whatever this SDK's API declares -
# pinning the whole header value passes only for a prefix-less API, and
# this file ships to every project that selects the feature.
sub credential_is {
  my ($header, $token, $label) = @_;
  my $got = defined $header ? "$header" : '';
  ok(($got eq $token || $got =~ /\s\Q$token\E\z/),
    ($label || 'credential') . ": expected the Authorization header to carry"
      . " $token, got: '$got'");
}


sub no_credential {
  my ($header, $label) = @_;
  ok(!defined $header,
    ($label || 'credential') . ': expected NO Authorization header, got: '
      . (defined $header ? "'$header'" : '(none)'));
}


# A LIVE client. `allow.op` is named explicitly: a project that narrows
# the default set would otherwise turn these into a false RED (the control
# leg refused before it reached the transport), and the rule under test
# lives at the transport, downstream of the allow gate either way.
sub live_sdk {
  my ($stub, $opts) = @_;
  my %o = %{ $opts || {} };
  $o{base} = $RAWBASE unless exists $o{base};
  $o{allow} = { 'op' => 'direct,graphql,list,load,create,update,remove' }
    unless exists $o{allow};
  $o{system} = { 'fetch' => $stub->{fetch} };
  return UnivecSDK->new(\%o);
}


sub secrets_sdk {
  my ($stub, $sopts, $extra) = @_;
  my %o = %{ $extra || {} };
  $o{feature} = { 'secrets' => { 'active' => 1, %$sopts } };
  return live_sdk($stub, \%o);
}


# An env chain, the shape most of these tests use.
sub envchain {
  my (%extra) = @_;
  return { 'providers' => [{ 'kind' => 'env', 'prefix' => $ENVPREFIX }], %extra };
}


my $BROKEN = {
  'lookup' => sub { die "vault unreachable\n" },
  'describe' => sub { 'broken:test' },
};

my $WORKING = {
  'lookup' => sub { my ($n) = @_; return 'apikey' eq $n ? 'RAWKEY01' : undef },
  'describe' => sub { 'working:test' },
};


# The first entity with a `list` op, discovered from the SDK's own config
# rather than named: this file is a TEMPLATE and no project's entity names
# are known here. SEARCH rather than taking the first entity and hoping -
# an API's first entity by name need not have a list.
sub listable_op {
  my ($sdk) = @_;
  my $entities = UnivecHelpers::to_map(
    UnivecHelpers::gp($sdk->options_map, 'entity')) || {};
  for my $name (sort keys %$entities) {
    my $accessor = ucfirst($name);
    next unless $sdk->can($accessor);
    my $ent = eval { $sdk->$accessor() };
    next unless defined $ent && Scalar::Util::blessed($ent) && $ent->can('list');
    return sub { return $ent->list() };
  }
  return undef;
}


sub clear_env {
  delete $ENV{$ENVPREFIX . 'APIKEY'};
  delete $ENV{$ENVPREFIX . 'API_TOKEN'};
  delete $ENV{$ENVPREFIX . 'REFRESH_TOKEN'};
}


# --- Inactive: the feature costs nothing -----------------------------------

{
  clear_env();

  my $stub = counting_fetch();
  my $sdk = live_sdk($stub, { 'apikey' => 'OPTKEY01' });
  $sdk->direct({ 'path' => '/thing' });

  is($stub->{sent}, 1, 'inactive: the request went out');
  credential_is($stub->{calls}[0]{auth}, 'OPTKEY01',
    'inactive: apikey option behaves exactly as before');

  # No feature, no instance: the accessor is the only way in.
  is($sdk->secrets, undef, 'inactive: no live sekreto');
}

{
  my $stub = counting_fetch();
  my $sdk = live_sdk($stub, {});
  $sdk->direct({ 'path' => '/thing' });

  is($stub->{sent}, 1, 'inactive: the request went out');
  no_credential($stub->{calls}[0]{auth}, 'inactive: no apikey, no header');
}


# --- Active: where the credential comes from -------------------------------

{
  clear_env();
  $ENV{$ENVPREFIX . 'APIKEY'} = 'ENVKEY01';

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, envchain(), { 'apikey' => 'OPTKEY01' });
  $sdk->direct({ 'path' => '/thing' });

  credential_is($stub->{calls}[0]{auth}, 'OPTKEY01',
    'active: an explicit apikey still wins over the chain');

  # The explicit option is a real store, not a special case: a directed
  # read names it like any other.
  is($sdk->secrets->getfrom('options', 'apikey'), 'OPTKEY01',
    'active: the explicit apikey is the `options` memory store');
}

# The three ways an apikey can be "not given", pinned together because
# they are easy to conflate and only one of them is a suppression.
# make_options normalises an omitted apikey to '' before features
# initialise, so by init time omitted and explicit-empty are
# indistinguishable - both defer to the chain, deliberately.
{
  clear_env();
  $ENV{$ENVPREFIX . 'APIKEY'} = 'ENVKEY01';

  my $stub = counting_fetch();
  secrets_sdk($stub, envchain())->direct({ 'path' => '/thing' });
  credential_is($stub->{calls}[0]{auth}, 'ENVKEY01',
    'active: an OMITTED apikey defers to the chain');

  my $stub2 = counting_fetch();
  secrets_sdk($stub2, envchain(), { 'apikey' => '' })->direct({ 'path' => '/thing' });
  credential_is($stub2->{calls}[0]{auth}, 'ENVKEY01',
    'active: an explicitly EMPTY apikey also defers to the chain');
}

# THE PERL SPELLING OF A CUSTOM PROVIDER IS A MAP OF CALLABLES.
#
# make_options deep-clones the option tree, and Voxgig::Struct::clone
# UNBLESSES objects while preserving coderefs - so the ts contract
# ("custom provider objects are accepted verbatim") cannot hold here: a
# blessed provider arrives at the feature as a plain hash with no methods.
# A map of callables is what survives, and it is what the docs use.
{
  clear_env();

  my @asked;
  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, {
    'providers' => [{
      'lookup' => sub { push @asked, $_[0]; return 'CUSTOM01' },
      'describe' => sub { 'custom:test' },
    }],
  });
  $sdk->direct({ 'path' => '/thing' });

  credential_is($stub->{calls}[0]{auth}, 'CUSTOM01',
    'active: a map of callables is a provider');
  is_deeply(\@asked, ['apikey'], 'active: the custom provider was asked once');
}

# ...and a map that is NEITHER a spec NOR a provider is refused by name,
# rather than failing deep inside the plugin host with an unrelated
# message. This is the shape a caller gets by passing a blessed provider
# object, which the option clone flattens.
{
  clear_env();

  my $stub = counting_fetch();
  my $res = secrets_sdk($stub, { 'providers' => [{ 'notaprovider' => 1 }] })
    ->direct({ 'path' => '/thing' });

  is($stub->{sent}, 0,
    'active: a malformed provider must not send an unauthenticated request,'
      . ' but one reached the transport: ' . wire($stub));
  is($res->{ok}, 0, 'active: a malformed provider fails the request');
  like("$res->{err}", qr/blessed provider object cannot survive/,
    'active: the refusal names the shape problem');
}

{
  clear_env();

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, envchain());
  my $res = $sdk->direct({ 'path' => '/thing' });

  is($stub->{sent}, 1, 'active: a miss everywhere still sends the request');
  no_credential($stub->{calls}[0]{auth},
    'active: a miss everywhere leaves the header off');
  is($res->{ok}, 1, 'active: the request succeeded unauthenticated');
}


# --- FAIL CLOSED -----------------------------------------------------------
#
# sekreto's miss-vs-error invariant: a MISS falls through to the next
# provider, an ERROR does not. A broken vault must never degrade into an
# unauthenticated request.

{
  clear_env();

  # THE RULE, asserted first so a regression reports the leak itself.
  my $stub = counting_fetch();
  my $res = secrets_sdk($stub, { 'providers' => [$BROKEN] })
    ->direct({ 'path' => '/thing' });

  is($stub->{sent}, 0,
    'direct: a request must not go out unauthenticated because a provider'
      . ' broke, but one reached the transport: ' . wire($stub));
  is($res->{ok}, 0, 'direct: the operation failed');
  like("$res->{err}", qr/vault unreachable/,
    "direct: the failure carries the PROVIDER'S own message");

  # CONTROL, which makes that zero mean REFUSED rather than UNWIRED.
  my $control = counting_fetch();
  my $ok = secrets_sdk($control, { 'providers' => [$WORKING] })
    ->direct({ 'path' => '/thing' });

  is($ok->{ok}, 1, 'direct control: the request succeeded');
  is($control->{sent}, 1,
    'direct control: the request never reached system.fetch, so this test'
      . ' cannot observe a request going out at all');
  credential_is($control->{calls}[0]{auth}, 'RAWKEY01', 'direct control');
}

{
  clear_env();

  my $stub = counting_fetch();
  my $res = secrets_sdk($stub, { 'providers' => [$BROKEN] })
    ->graphql('{ thing }', {});

  is($stub->{sent}, 0,
    'graphql: a request must not go out unauthenticated, but one reached'
      . ' the transport: ' . wire($stub));
  is($res->{ok}, 0, 'graphql: the operation failed');
  like("$res->{err}", qr/vault unreachable/,
    "graphql: the failure carries the PROVIDER'S own message");

  my $control = counting_fetch();
  my $ok = secrets_sdk($control, { 'providers' => [$WORKING] })
    ->graphql('{ thing }', {});

  is($ok->{ok}, 1, 'graphql control: the request succeeded');
  is($control->{sent}, 1,
    'graphql control: the request never reached system.fetch, so this test'
      . ' cannot observe a request going out at all');
  credential_is($control->{calls}[0]{auth}, 'RAWKEY01', 'graphql control');
}

# The ENTITY path, which DOES run feature hooks - so it must fail closed
# for the same reason and by the same rule.
SKIP: {
  clear_env();

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, { 'providers' => [$BROKEN] });
  my $op = listable_op($sdk);

  skip('this SDK has no listable entity', 5) unless defined $op;

  my $out = eval { $op->(); 1 };
  my $err = $@;

  ok(!$out, 'entity: a broken provider fails the operation');
  like("$err", qr/vault unreachable/,
    "entity: the failure carries the PROVIDER'S own message");
  is($stub->{sent}, 0,
    'entity: a request must not go out unauthenticated because a provider'
      . ' broke, but one reached the transport: ' . wire($stub));

  my $control = counting_fetch();
  my $csdk = secrets_sdk($control, { 'providers' => [$WORKING] });
  my $cop = listable_op($csdk);
  eval { $cop->() };

  is($control->{sent}, 1,
    'entity control: the request never reached system.fetch, so this test'
      . ' cannot observe a request going out at all');
  credential_is($control->{calls}[0]{auth}, 'RAWKEY01', 'entity control');
}

# A failure must not be REMEMBERED. Holding one meant a transient vault
# outage poisoned the client permanently: every later operation kept
# failing with the original error long after the vault recovered.
{
  clear_env();

  my $calls = 0;
  my $flaky = {
    'lookup' => sub {
      $calls++;
      die "vault unreachable\n" if 1 == $calls;
      return 'RECOVERED01';
    },
    'describe' => sub { 'flaky:test' },
  };

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, { 'providers' => [$flaky] });

  my $first = $sdk->direct({ 'path' => '/thing' });
  is($first->{ok}, 0, 'recovery: the first attempt surfaces the outage');
  is($stub->{sent}, 0, 'recovery: nothing went out during the outage');

  my $second = $sdk->direct({ 'path' => '/thing' });
  is($second->{ok}, 1, 'recovery: the second attempt recovers');
  is($stub->{sent}, 1, 'recovery: exactly one request went out');
  credential_is($stub->{calls}[0]{auth}, 'RECOVERED01',
    'recovery: the FRESH credential, never the stale one and never nothing');
}


# --- auth: null suppresses -------------------------------------------------
#
# `auth => undef` is the documented way to disable auth outright, and
# prepare_auth honours it before it ever reads the apikey. The transport
# seam has to honour it too, or the feature would put back exactly the
# credential the caller withheld.

{
  clear_env();
  $ENV{$ENVPREFIX . 'APIKEY'} = 'ENVKEY01';

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, envchain(), { 'auth' => undef });
  $sdk->direct({ 'path' => '/thing' });

  is($stub->{sent}, 1, 'auth null: the request still goes out');
  no_credential($stub->{calls}[0]{auth},
    'auth null suppresses the credential, chain or no chain');

  # The suppression survives option validation rather than being replaced
  # by the optspec default auth map.
  ok(!defined $sdk->options_map->{auth}, 'auth null survives validate');
}

{
  clear_env();

  my $stub = counting_fetch();
  secrets_sdk($stub, envchain(), { 'apikey' => 'OPTKEY01', 'auth' => undef })
    ->direct({ 'path' => '/thing' });

  no_credential($stub->{calls}[0]{auth},
    'auth null suppresses an EXPLICIT apikey too');
}


# --- cache -----------------------------------------------------------------

# A MISS IS NOT A CACHEABLE ANSWER - sekreto's own rule, which this feature
# used to override from the layer above.
#
# DEFAULT caching here, which is the whole point: `cache: true` is about
# holding a HIT (the block after next pins that half), and keeping the
# settled resolution after a miss meant the chain was never asked again for
# the life of the client. A secret provisioned after startup (a mounted
# file, a vault policy granted a minute late) was invisible forever.
{
  clear_env();

  my $calls = 0;
  my $present = 0;
  my $late = {
    'lookup' => sub { $calls++; return $present ? 'LATEKEY01' : undef },
    'describe' => sub { 'late:test' },
  };

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, { 'providers' => [$late] });

  $sdk->direct({ 'path' => '/one' });
  no_credential($stub->{calls}[0]{auth},
    'the chain has nothing yet, so no credential should go out');

  my $asked = $calls;
  ok(0 < $asked, 'the chain was asked at least once');

  # The secret is provisioned while the client is live.
  $present = 1;

  $sdk->direct({ 'path' => '/two' });

  ok($asked < $calls,
    'the MISS was cached: a secret that appears later can never be picked up');
  credential_is($stub->{calls}[1]{auth}, 'LATEKEY01', 'the late secret goes out');
}


{
  clear_env();

  my $calls = 0;
  my $counting = {
    'lookup' => sub { $calls++; return 'KEY' . $calls },
    'describe' => sub { 'counting:test' },
  };

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, { 'cache' => 0, 'providers' => [$counting] });
  $sdk->direct({ 'path' => '/one' });
  $sdk->direct({ 'path' => '/two' });

  is(scalar @{ $stub->{calls} }, 2, 'cache off: two requests');
  credential_is($stub->{calls}[0]{auth}, 'KEY1', 'cache off: first');
  credential_is($stub->{calls}[1]{auth}, 'KEY2',
    'cache false asks the chain on every request');
}

{
  clear_env();

  my $calls = 0;
  my $counting = {
    'lookup' => sub { $calls++; return 'KEY' . $calls },
    'describe' => sub { 'counting:test' },
  };

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, { 'providers' => [$counting] });
  $sdk->direct({ 'path' => '/one' });
  $sdk->direct({ 'path' => '/two' });

  is($calls, 1, 'cache on: a cached success asks the chain once');
  credential_is($stub->{calls}[1]{auth}, 'KEY1', 'cache on: same credential');
}

# An UNCACHED miss after an earlier hit is a REVOCATION: the chain now
# says no provider has the secret, so the resolved value must not keep
# going out on the wire.
{
  clear_env();

  my $calls = 0;
  my $revoking = {
    'lookup' => sub { $calls++; return 1 == $calls ? 'BEFORE01' : undef },
    'describe' => sub { 'revoking:test' },
  };

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, { 'cache' => 0, 'providers' => [$revoking] });
  $sdk->direct({ 'path' => '/one' });
  $sdk->direct({ 'path' => '/two' });

  credential_is($stub->{calls}[0]{auth}, 'BEFORE01', 'revocation: before');
  no_credential($stub->{calls}[1]{auth},
    'an uncached miss after a hit RETRACTS the credential');
}

# ...and an explicit apikey OPTION is never lost that way: it seats FIRST
# in the chain as a memory provider, so the chain HITS while one is set.
{
  clear_env();

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub,
    { 'cache' => 0, 'providers' => [{
      'lookup' => sub { undef }, 'describe' => sub { 'empty:test' } }] },
    { 'apikey' => 'OPTKEY01' });
  $sdk->direct({ 'path' => '/one' });
  $sdk->direct({ 'path' => '/two' });

  credential_is($stub->{calls}[1]{auth}, 'OPTKEY01',
    'an explicit apikey is never retracted by an uncached miss');
}


# --- the secret name, and the live Sekreto ---------------------------------

{
  clear_env();
  $ENV{$ENVPREFIX . 'API_TOKEN'} = 'TOKKEY01';

  my $stub = counting_fetch();
  secrets_sdk($stub, envchain('name' => 'api.token'))->direct({ 'path' => '/t' });
  credential_is($stub->{calls}[0]{auth}, 'TOKKEY01',
    'the secret name is configurable');
  clear_env();
}

{
  clear_env();

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, {
    'providers' => [{ 'kind' => 'memory', 'values' => { 'DB_PASSWORD' => 'dbpass01' } }],
  });

  my $secrets = $sdk->secrets;
  ok(defined $secrets, 'the live sekreto is reachable through the accessor');
  is($secrets->get('db.password'), 'dbpass01',
    'sekreto is live for arbitrary secrets');
  is($secrets->redactall('the password is dbpass01, keep it safe'),
    'the password is [redacted], keep it safe',
    'sekreto is live for redaction');
}

# THE PROVIDER VOCABULARY IS NON-EMPTY.
#
# Construction is where an unknown kind is refused, so the Sekreto being
# built at all IS the regression check: if Config emitted no
# FEATURE_PLUGINS table (or the feature failed to read it), the chain
# below is refused and the request never goes out. The memory store comes
# FIRST so sekreto's first-hit rule answers from it and the vault is never
# contacted - the kind has to be DECLARABLE, not reachable.
#
# Conditional on the module being present, because this file ships to
# projects that select the feature without the `vault` plugin group.
SKIP: {
  clear_env();

  my $vaultmod = "$FindBin::Bin/../../../feature/secrets/plugins/Voxgig/Sekreto/Plugins/Hashicorp.pm";
  skip('no vault plugin group in this project', 2) unless -f $vaultmod;

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, {
    'providers' => [
      { 'kind' => 'memory', 'values' => { 'APIKEY' => 'VOCAB01' } },
      { 'kind' => 'hashicorp', 'addr' => 'https://vault.test', 'token' => 'x' },
    ],
  });
  my $res = $sdk->direct({ 'path' => '/thing' });

  is($res->{ok}, 1, 'vocabulary: a selected plugin kind is declarable');
  credential_is($stub->{calls}[0]{auth}, 'VOCAB01', 'vocabulary');
}

# FEATURE ORDER decides wrapper nesting. Main adds features in
# __derived__.featureorder - test first, then sorted - so `secrets` lands
# after retry/cache/ratelimit and sits OUTERMOST: one credential
# injection, retried underneath. That is correct, but it is an emergent
# property of alphabetical ordering rather than a declaration, so pin it.
{
  clear_env();

  my $stub = counting_fetch();
  my $sdk = secrets_sdk($stub, { 'providers' => [$WORKING] });
  my $order = UnivecHelpers::gpath($sdk->options_map,
    '__derived__.featureorder');
  $order = [] unless Voxgig::Struct::islist($order);

  my ($si) = grep { 'secrets' eq $order->[$_] } 0 .. $#$order;
  ok(defined $si, 'secrets is in the resolved feature order');

  my @transport = grep { defined }
    map { my $n = $_; (grep { $n eq $order->[$_] } 0 .. $#$order)[0] }
    qw(retry cache ratelimit netsim proxy timeout);
  my $late = 1;
  for my $i (@transport) {
    $late = 0 if $i > $si;
  }
  ok($late, 'secrets is added after every transport-wrapping feature,'
    . ' so its credential injection sits OUTERMOST');
}


# --- ACCESS-TOKEN EXCHANGE -------------------------------------------------
#
# What the chain resolves is a REFRESH token, which is POSTed to a token
# endpoint for a short-lived ACCESS token; the access token is what the
# Authorization header carries; and when the API answers 401 the client
# buys another and tries the same request again, once.

sub exchange_sdk {
  my ($stub, $x, $extra) = @_;
  my %o = %{ $extra || {} };
  $o{base} = $XBASE;
  return secrets_sdk($stub, {
    'name' => 'refresh_token',
    'providers' => [{ 'kind' => 'env', 'prefix' => $ENVPREFIX }],
    'exchange' => { 'active' => 1, %{ $x || {} } },
  }, \%o);
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  my $stub = counting_fetch();
  exchange_sdk($stub)->direct({ 'path' => '/thing' });

  is(scalar @{ token_calls($stub) }, 1, 'exchange: exactly one purchase');
  is_deeply(Voxgig::Struct::parse_json(token_calls($stub)->[0]{body}),
    { 'refresh_token' => 'REFRESH01' },
    'exchange: the refresh token is sent in the request field');
  is(scalar @{ api_calls($stub) }, 1, 'exchange: one API call');
  credential_is(api_calls($stub)->[0]{auth}, 'ACCESS01',
    'exchange: the request carries the access token');
}

# The body is MARSHALLED, not concatenated: a refresh token carrying a
# quote, backslash or newline must arrive as that literal value.
{
  clear_env();
  my $nasty = qq{a"b\\c\nd};
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = $nasty;

  my $stub = counting_fetch();
  exchange_sdk($stub)->direct({ 'path' => '/thing' });

  is_deeply(Voxgig::Struct::parse_json(token_calls($stub)->[0]{body}),
    { 'refresh_token' => $nasty },
    'exchange: the request body is marshalled, not concatenated');
  clear_env();
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'FROMCHAIN';

  my $stub = counting_fetch();
  exchange_sdk($stub, { 'refresh' => 'EXPLICIT01' })->direct({ 'path' => '/thing' });

  is_deeply(Voxgig::Struct::parse_json(token_calls($stub)->[0]{body}),
    { 'refresh_token' => 'EXPLICIT01' },
    'exchange: an explicit exchange.refresh wins over the chain');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  my $stub = counting_fetch();
  my $sdk = exchange_sdk($stub);
  $sdk->direct({ 'path' => '/one' });
  $sdk->direct({ 'path' => '/two' });
  $sdk->direct({ 'path' => '/three' });

  is(scalar @{ token_calls($stub) }, 1,
    'exchange: a token still working must not be re-bought');
  is(scalar @{ api_calls($stub) }, 3, 'exchange: one purchase serves many');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  # First API call is refused, the retry succeeds.
  my $stub = counting_fetch('apistatus' => [401, 200]);
  my $res = exchange_sdk($stub)->direct({ 'path' => '/thing' });

  is(scalar @{ token_calls($stub) }, 2, 'exchange: a second purchase');
  is(scalar @{ api_calls($stub) }, 2, 'exchange: the request was retried');
  credential_is(api_calls($stub)->[0]{auth}, 'ACCESS01', 'exchange: first try');
  credential_is(api_calls($stub)->[1]{auth}, 'ACCESS02',
    'exchange: the retry carries the NEW token, not the spent one');
  is($res->{ok}, 1, 'exchange: the caller sees the successful retry');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  # Every API call is refused: a second 401 on a token bought moments ago
  # is a real failure, and spinning on it would hang instead of failing.
  my $stub = counting_fetch('apistatus' => [401]);
  exchange_sdk($stub)->direct({ 'path' => '/thing' });

  is(scalar @{ api_calls($stub) }, 2, 'exchange: exactly one retry');
  is(scalar @{ token_calls($stub) }, 2, 'exchange: exactly two purchases');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  my $stub = counting_fetch('apistatus' => [403]);
  exchange_sdk($stub)->direct({ 'path' => '/thing' });

  is(scalar @{ api_calls($stub) }, 1,
    'exchange: 403 is not in the default statuses');
  is(scalar @{ token_calls($stub) }, 1, 'exchange: no extra purchase');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  my $stub = counting_fetch('apistatus' => [403, 200]);
  exchange_sdk($stub, { 'statuses' => [403] })->direct({ 'path' => '/thing' });

  is(scalar @{ api_calls($stub) }, 2, 'exchange: statuses is configurable');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  my $stub = counting_fetch('path' => 'oauth/grant', 'response' => 'token');
  exchange_sdk($stub, {
    'path' => 'oauth/grant', 'request' => 'grant', 'response' => 'token',
  })->direct({ 'path' => '/thing' });

  is(scalar @{ token_calls($stub) }, 1, 'exchange: one purchase');
  like(token_calls($stub)->[0]{url}, qr{\Q$XBASE\E/oauth/grant\z},
    'exchange: the token endpoint is relative to base');
  is_deeply(Voxgig::Struct::parse_json(token_calls($stub)->[0]{body}),
    { 'grant' => 'REFRESH01' }, 'exchange: the request field is configurable');
  credential_is(api_calls($stub)->[0]{auth}, 'ACCESS01',
    'exchange: the response field is configurable');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  # A caller who already holds an access token should use it; expiry is
  # what moves them onto the exchange, and the API is what says so.
  my $stub = counting_fetch();
  exchange_sdk($stub, {}, { 'apikey' => 'HELDTOKEN01' })
    ->direct({ 'path' => '/thing' });

  is(scalar @{ token_calls($stub) }, 0, 'exchange: nothing needed buying');
  credential_is(api_calls($stub)->[0]{auth}, 'HELDTOKEN01',
    'exchange: an explicit apikey is spent before anything is bought');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  my $stub = counting_fetch('apistatus' => [401, 200]);
  exchange_sdk($stub, {}, { 'apikey' => 'STALETOKEN01' })
    ->direct({ 'path' => '/thing' });

  credential_is(api_calls($stub)->[0]{auth}, 'STALETOKEN01', 'exchange: stale');
  credential_is(api_calls($stub)->[1]{auth}, 'ACCESS01',
    'exchange: a spent apikey falls through to the exchange');
}

{
  clear_env();

  my $stub = counting_fetch();
  my $res = exchange_sdk($stub)->direct({ 'path' => '/thing' });

  is($res->{ok}, 0,
    'exchange: no refresh token anywhere is an ERROR, not an unauthenticated call');
  like("$res->{err}", qr/no refresh token/, 'exchange: the refusal says why');
  is(scalar @{ api_calls($stub) }, 0,
    'exchange: a request must not go out because the chain was empty,'
      . ' but one reached the transport: ' . wire($stub));
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  # The first purchase succeeds; the second (after the 401) does not.
  my $stub = counting_fetch('apistatus' => [401]);
  my $inner = $stub->{fetch};
  my $wrapped = {
    'sent' => 0, 'calls' => $stub->{calls}, 'istoken' => $stub->{istoken},
  };
  $wrapped->{fetch} = sub {
    my ($url, $fetchdef) = @_;
    my ($res, $err) = $inner->($url, $fetchdef);
    if ($stub->{istoken}->($url) && 1 < scalar @{ token_calls($stub) }) {
      return ({ 'status' => 500, 'statusText' => 'ERR', 'headers' => {},
        'json' => sub { {} }, 'body' => '{}' }, undef);
    }
    return ($res, $err);
  };

  my $res = exchange_sdk($wrapped)->direct({ 'path' => '/thing' });

  ok(defined $res, 'exchange: the caller got an answer rather than a hang');
  is(scalar @{ api_calls($stub) }, 1,
    'exchange: no retry after a failed purchase - the API refusal stands');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  # `auth => undef` is the documented way to send no credential at all. A
  # refusal of a deliberately unauthenticated request is not an expired
  # token: buying one and retrying would transmit exactly the credential
  # the caller suppressed.
  my $stub = counting_fetch('apistatus' => [401]);
  exchange_sdk($stub, {}, { 'auth' => undef })->direct({ 'path' => '/thing' });

  is(scalar @{ api_calls($stub) }, 1,
    'exchange: a suppressed request must not be retried');
  no_credential(api_calls($stub)->[0]{auth},
    'exchange: no credential may be sent when auth is suppressed');

  # AND NO PURCHASE. resolve runs before _with_refresh's suppression check,
  # so the refresh token used to go to the token endpoint in a request body
  # even here. Stopping the retry does not unsend it, and only the token
  # endpoint can see this.
  is(scalar @{ token_calls($stub) }, 0,
    'exchange: auth undef suppressed the credential but the refresh token '
      . 'was still POSTed to the exchange endpoint');
}

{
  clear_env();
  $ENV{$ENVPREFIX . 'APIKEY'} = 'PLAINKEY01';

  my $stub = counting_fetch();
  secrets_sdk($stub, envchain())->direct({ 'path' => '/thing' });

  credential_is($stub->{calls}[0]{auth}, 'PLAINKEY01',
    'exchange off leaves the feature exactly as it was');
  clear_env();
}

# TEST MODE BUYS NOTHING: the test feature replaces the transport so no
# request leaves the process, and an exchange would be the one HTTP call
# it could not stop.
{
  clear_env();
  $ENV{$ENVPREFIX . 'REFRESH_TOKEN'} = 'REFRESH01';

  my $stub = counting_fetch();
  my $sdk = UnivecSDK->test({}, {
    'base' => $XBASE,
    'system' => { 'fetch' => $stub->{fetch} },
    'feature' => {
      'secrets' => {
        'active' => 1,
        'name' => 'refresh_token',
        'providers' => [{ 'kind' => 'env', 'prefix' => $ENVPREFIX }],
        'exchange' => { 'active' => 1 },
      },
    },
  });

  my $f = $sdk->{_secrets};
  ok(defined $f, 'test mode: the feature initialised');
  my $err = $f->resolve;
  is($err, undef, 'test mode: resolution needs no token endpoint');
  is(scalar @{ $stub->{calls} }, 0, 'test mode must not do IO');
  # A deterministic placeholder, so offline suites need no configuration.
  is($f->credential, 'test-access_token', 'test mode: a fake access token');
  clear_env();
}

clear_env();

done_testing;
