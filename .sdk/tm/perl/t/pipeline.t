#!perl
# Univec SDK pipeline test
#
# Direct unit tests for the operation-pipeline utilities. The generated
# entity tests exercise the happy path; these drive the error and edge
# branches (missing spec/response/result, 4xx handling, transport
# failures, feature ordering, auth header shaping) that a normal
# success-path op never reaches. All utilities are reached through the
# client's utility view, so this suite is API-agnostic.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Scalar::Util ();

use UnivecSDK;

my $client = UnivecSDK->test(undef, undef);
my $utility = $client->get_utility;

# Fake client so the exact options shape is controlled (prepare_auth).
{
  package PipelineOptClient;

  sub new {
    my ($class, $options) = @_;
    return bless { options => $options }, $class;
  }

  sub options_map {
    my ($self) = @_;
    my $out = Voxgig::Struct::clone($self->{options});
    return Voxgig::Struct::ismap($out) ? $out : {};
  }
}

# Fake entity whose make() records data_set payloads (make_result list op).
{
  package PipelineFakeEntityRec;

  sub new { my ($class, $made) = @_; return bless { made => $made }, $class }
  sub data_set { my ($self, $d) = @_; push @{ $self->{made} }, $d; return }

  package PipelineFakeEntity;

  sub new { my ($class, $made) = @_; return bless { made => $made }, $class }
  sub make { my ($self) = @_; return PipelineFakeEntityRec->new($self->{made}) }
}

sub make_ctx {
  my (%args) = @_;
  my $u = $args{utility} || $utility;
  my $c = $args{client} || $client;
  my $ctx = $u->{make_context}->({
    'opname' => ($args{opname} || 'load'),
    'client' => $c,
    'utility' => $u,
  }, undef);
  if (!defined $ctx->{options} && $c->can('options_map')) {
    $ctx->{options} = $c->options_map;
  }
  return $ctx;
}

# Transport-shaped response with a re-readable body + lowercase headers.
sub resp {
  my ($status, $data, $headers) = @_;
  my $h = {};
  for my $k (keys %{ $headers || {} }) {
    $h->{lc $k} = $headers->{$k};
  }
  return UnivecResponse->new({
    'status' => $status,
    'statusText' => ($status < 400 ? 'OK' : 'ERR'),
    'body' => 'body',
    'json' => sub { $data },
    'headers' => $h,
  });
}

sub spec_of {
  my (%map) = @_;
  return UnivecSpec->new({
    'step' => 's', 'method' => 'GET', 'headers' => {}, %map });
}

# A utility view whose fetcher is overridden.
sub util_with {
  my ($fetcher) = @_;
  my $u = $client->get_utility;
  $u->{fetcher} = $fetcher;
  return $u;
}

sub is_sdk_error {
  my ($err) = @_;
  return Scalar::Util::blessed($err) && $err->isa('UnivecError');
}


# === make_point ===

{
  my $ctx = make_ctx(opname => 'nope');
  my (undef, $err) = $utility->{make_point}->($ctx);
  is($err->{code}, 'point_op_allow', 'make_point rejects a disallowed operation');
}

{
  my $ctx = make_ctx();
  $ctx->{op}{points} = [];
  my (undef, $err) = $utility->{make_point}->($ctx);
  is($err->{code}, 'point_no_points', 'make_point rejects an operation with no endpoints');
}

{
  my $ctx = make_ctx();
  my $point = { 'parts' => ['a'], 'args' => { 'params' => [] } };
  $ctx->{op}{points} = [$point];
  my ($out, $err) = $utility->{make_point}->($ctx);
  ok(!defined $err, 'make_point single point: no error');
  is($out, $point, 'make_point returns the single point');
}

{
  my $ctx = make_ctx();
  my $preset = { 'parts' => ['a'] };
  $ctx->{out}{point} = $preset;
  my ($out, $err) = $utility->{make_point}->($ctx);
  ok(!defined $err, 'make_point preset: no error');
  is($out, $preset, 'make_point short-circuits a feature-supplied point');
}

{
  # The PrePoint short-circuit analog: a feature (e.g. rbac) places an
  # error in ctx.out.point; make_point must fail before any network.
  my $ctx = make_ctx();
  my $denial = $ctx->make_error('rbac_denied', 'denied');
  $ctx->{out}{point} = $denial;
  my ($out, $err) = $utility->{make_point}->($ctx);
  ok(!defined $out, 'make_point feature error: no point');
  is($err->{code}, 'rbac_denied', 'make_point surfaces a feature-supplied error');
}


# === make_spec ===

{
  my $ctx = make_ctx();
  my $preset = spec_of('method' => 'GET');
  $ctx->{out}{spec} = $preset;
  my ($out, $err) = $utility->{make_spec}->($ctx);
  ok(!defined $err, 'make_spec preset: no error');
  is($out, $preset, 'make_spec short-circuits a feature-supplied spec');
}


# === make_response ===

{
  my $ctx = make_ctx();
  $ctx->{spec} = undef;
  $ctx->{response} = resp(200);
  $ctx->{result} = UnivecResult->new({});
  my (undef, $err) = $utility->{make_response}->($ctx);
  is($err->{code}, 'response_no_spec', 'make_response guards missing spec');

  $ctx = make_ctx();
  $ctx->{spec} = spec_of();
  $ctx->{response} = undef;
  $ctx->{result} = UnivecResult->new({});
  (undef, $err) = $utility->{make_response}->($ctx);
  is($err->{code}, 'response_no_response', 'make_response guards missing response');

  $ctx = make_ctx();
  $ctx->{spec} = spec_of();
  $ctx->{response} = resp(200);
  $ctx->{result} = undef;
  (undef, $err) = $utility->{make_response}->($ctx);
  is($err->{code}, 'response_no_result', 'make_response guards missing result');
}

{
  my $ctx = make_ctx();
  $ctx->{spec} = spec_of();
  $ctx->{response} = resp(404, undef, { 'x-a' => '1' });
  $ctx->{result} = UnivecResult->new({});
  my (undef, $err) = $utility->{make_response}->($ctx);
  ok(!defined $err, 'make_response 4xx: no tuple error');
  ok(defined $ctx->{result}{err}, 'make_response 4xx sets result err');
  is($ctx->{result}{status}, 404, 'make_response 4xx status');
  is($ctx->{result}{headers}{'x-a'}, '1', 'make_response 4xx copies headers');
  ok(!$ctx->{result}{ok}, 'make_response 4xx not ok');
}

{
  my $ctx = make_ctx();
  $ctx->{spec} = spec_of();
  $ctx->{response} = resp(200, { 'v' => 1 });
  $ctx->{result} = UnivecResult->new({});
  my (undef, $err) = $utility->{make_response}->($ctx);
  ok(!defined $err, 'make_response 2xx: no error');
  ok($ctx->{result}{ok}, 'make_response 2xx marks ok');
  is_deeply($ctx->{result}{body}, { 'v' => 1 }, 'make_response 2xx parses body');
}

{
  my $ctx = make_ctx();
  $ctx->{ctrl}{explain} = {};
  $ctx->{spec} = spec_of();
  $ctx->{response} = resp(200, { 'v' => 2 });
  $ctx->{result} = UnivecResult->new({});
  $utility->{make_response}->($ctx);
  ok(defined $ctx->{ctrl}{explain}{result}, 'make_response records to ctrl explain');
}

{
  my $ctx = make_ctx();
  my $preset = resp(299);
  $ctx->{out}{response} = $preset;
  $ctx->{spec} = spec_of();
  $ctx->{response} = resp(200);
  $ctx->{result} = UnivecResult->new({});
  my ($out, $err) = $utility->{make_response}->($ctx);
  ok(!defined $err, 'make_response preset: no error');
  is($out, $preset, 'make_response short-circuits a feature-supplied response');
}


# === make_result ===

{
  my $ctx = make_ctx();
  $ctx->{spec} = undef;
  $ctx->{result} = UnivecResult->new({});
  my (undef, $err) = $utility->{make_result}->($ctx);
  is($err->{code}, 'result_no_spec', 'make_result guards missing spec');

  $ctx = make_ctx();
  $ctx->{spec} = spec_of();
  $ctx->{result} = undef;
  (undef, $err) = $utility->{make_result}->($ctx);
  is($err->{code}, 'result_no_result', 'make_result guards missing result');
}

{
  my $made = [];
  my $ctx = $utility->{make_context}->({
    'opname' => 'list',
    'client' => $client,
    'utility' => $utility,
    'entity' => PipelineFakeEntity->new($made),
  }, undef);
  $ctx->{spec} = spec_of();
  $ctx->{result} = UnivecResult->new({
    'ok' => 1, 'resdata' => [{ 'a' => 1 }, { 'a' => 2 }],
  });
  my ($result, $err) = $utility->{make_result}->($ctx);
  ok(!defined $err, 'make_result list op: no error');
  is(scalar @{ $result->{resdata} }, 2, 'make_result list op wraps resdata into entities');
  is(scalar @$made, 2, 'make_result list op called data_set per entry');
  is_deeply($made, [{ 'a' => 1 }, { 'a' => 2 }], 'make_result list op data_set payloads');
}

{
  my $made = [];
  my $ctx = $utility->{make_context}->({
    'opname' => 'list',
    'client' => $client,
    'utility' => $utility,
    'entity' => PipelineFakeEntity->new($made),
  }, undef);
  $ctx->{spec} = spec_of();
  $ctx->{result} = UnivecResult->new({ 'ok' => 1, 'resdata' => [] });
  my ($result, $err) = $utility->{make_result}->($ctx);
  ok(!defined $err, 'make_result empty list: no error');
  is_deeply($result->{resdata}, [], 'make_result empty list yields an empty resdata array');
}

{
  my $ctx = make_ctx();
  my $preset = UnivecResult->new({ 'ok' => 1 });
  $ctx->{out}{result} = $preset;
  my ($out, $err) = $utility->{make_result}->($ctx);
  ok(!defined $err, 'make_result preset: no error');
  is($out, $preset, 'make_result short-circuits a preset result');
}


# === make_request ===

{
  my $ctx = make_ctx();
  $ctx->{spec} = undef;
  my (undef, $err) = $utility->{make_request}->($ctx);
  is($err->{code}, 'request_no_spec', 'make_request guards a missing spec');
}

sub request_spec {
  return spec_of('base' => 'http://h', 'path' => 'a');
}

{
  my $boom = UnivecError->new('boom', 'boom');
  my $u = util_with(sub { return (undef, $boom) });
  my $ctx = make_ctx(utility => $u);
  $ctx->{spec} = request_spec();
  my ($response, $err) = $u->{make_request}->($ctx);
  ok(!defined $err, 'make_request transport error tuple: no tuple error');
  is($response->{err}, $boom, 'make_request transport error tuple lands on the response');
}

{
  my $u = util_with(sub { return (undef, undef) });
  my $ctx = make_ctx(utility => $u);
  $ctx->{spec} = request_spec();
  my ($response, $err) = $u->{make_request}->($ctx);
  ok(!defined $err, 'make_request nil transport: no tuple error');
  ok(defined $response->{err}, 'make_request nil transport result becomes a response error');
}

{
  my $u = util_with(sub {
    return ({ 'status' => 200, 'statusText' => 'OK', 'headers' => {},
      'json' => sub { { 'a' => 1 } }, 'body' => 'b' }, undef);
  });
  my $ctx = make_ctx(utility => $u);
  $ctx->{spec} = request_spec();
  my ($response, $err) = $u->{make_request}->($ctx);
  ok(!defined $err, 'make_request normal: no error');
  is($response->{status}, 200, 'make_request wraps a normal transport response');
}

{
  my $u = util_with(sub {
    return ({ 'status' => 200, 'statusText' => 'OK', 'headers' => {},
      'json' => sub { undef }, 'body' => 'b' }, undef);
  });
  my $ctx = make_ctx(utility => $u);
  $ctx->{ctrl}{explain} = {};
  $ctx->{spec} = request_spec();
  $u->{make_request}->($ctx);
  ok(defined $ctx->{ctrl}{explain}{fetchdef}, 'make_request records the fetchdef to ctrl explain');
}

{
  my $u = $client->get_utility;
  $u->{make_fetch_def} = sub {
    return (undef, UnivecError->new('fetchdef_boom', 'boom'));
  };
  my $ctx = make_ctx(utility => $u);
  $ctx->{spec} = request_spec();
  my ($response, $err) = $u->{make_request}->($ctx);
  ok(!defined $err, 'make_request fetchdef error: no tuple error');
  ok(defined $response->{err}, 'make_request fetchdef error surfaces as a response error');
  is($response->{err}{code}, 'fetchdef_boom', 'make_request fetchdef error code');
}

{
  my $ctx = make_ctx();
  my $preset = resp(201);
  $ctx->{out}{request} = $preset;
  $ctx->{spec} = request_spec();
  my ($out, $err) = $utility->{make_request}->($ctx);
  ok(!defined $err, 'make_request preset: no error');
  is($out, $preset, 'make_request short-circuits a feature-supplied request');
}


# === make_fetch_def ===

{
  my $ctx = make_ctx();
  $ctx->{spec} = undef;
  my (undef, $err) = $utility->{make_fetch_def}->($ctx);
  is($err->{code}, 'fetchdef_no_spec', 'make_fetch_def guards a missing spec');
}

{
  my $ctx = make_ctx();
  $ctx->{result} = undef;
  $ctx->{spec} = spec_of(
    'method' => 'POST', 'base' => 'http://h', 'path' => 'a',
    'body' => { 'x' => 1 });
  my ($fetchdef, $err) = $utility->{make_fetch_def}->($ctx);
  ok(!defined $err, 'make_fetch_def body: no error');
  ok(defined $fetchdef->{body} && !ref $fetchdef->{body},
    'make_fetch_def serialises a hash body');
  like($fetchdef->{url}, qr{http://h}, 'make_fetch_def url includes base');
  ok(defined $ctx->{result}, 'make_fetch_def lazily created a missing result');
}


# === make_error + done ===

{
  my $ctx = make_ctx();
  $ctx->{result} = UnivecResult->new({ 'ok' => 1, 'resdata' => 42 });
  is($utility->{done}->($ctx), 42, 'done returns resdata on success');
}

{
  my $ctx = make_ctx();
  $ctx->{result} = UnivecResult->new({ 'ok' => 0 });
  my $out = eval { $utility->{done}->($ctx) };
  ok(is_sdk_error($@), 'done dies with the error when not ok');
}

{
  my $ctx = make_ctx();
  $ctx->{ctrl}{explain} = { 'result' => { 'err' => 'x' } };
  $ctx->{result} = UnivecResult->new({ 'ok' => 1, 'resdata' => 7 });
  is($utility->{done}->($ctx), 7, 'done cleans ctrl explain on success');
}

{
  my $ctx = make_ctx();
  $ctx->{ctrl}{throw_err} = 0;
  $ctx->{result} = UnivecResult->new({ 'ok' => 0, 'resdata' => 'fallback' });
  is($utility->{make_error}->($ctx, undef), 'fallback',
    'make_error returns resdata when throw is disabled');
}

{
  my $ctx = make_ctx();
  $ctx->{ctrl}{throw_err} = 0;
  $ctx->{ctrl}{explain} = {};
  $ctx->{result} = UnivecResult->new({ 'ok' => 0 });
  $utility->{make_error}->($ctx, undef);
  ok(defined $ctx->{ctrl}{explain}{err}, 'make_error records to ctrl explain');
}

{
  my $ctx = make_ctx();
  my $out = eval {
    $utility->{make_error}->($ctx, $ctx->make_error('rbac_denied', 'denied'));
  };
  ok(is_sdk_error($@), 'make_error dies');
  is($@->{code}, 'rbac_denied', 'make_error preserves the error code');
}


# === feature ordering ===

{
  my $oclient = UnivecSDK->test(undef, undef);
  my $outil = $oclient->get_utility;
  my $ctx = $outil->{make_context}->({
    'opname' => 'load', 'client' => $oclient, 'utility' => $outil,
  }, undef);

  $oclient->{features} = [];
  my $a = UnivecBaseFeature->new;
  my $b = UnivecBaseFeature->new;
  $outil->{feature_add}->($ctx, $a);
  $outil->{feature_add}->($ctx, $b);
  is_deeply($oclient->{features}, [$a, $b], 'feature_add appends in call order');
}

sub named_feature {
  my ($name) = @_;
  my $f = UnivecBaseFeature->new;
  $f->{name} = $name;
  return $f;
}

{
  # `_options` on an extend-feature instance positions it relative to an
  # already-added feature (mirrors the ts featureAdd).
  my $oclient = UnivecSDK->test(undef, undef);
  my $outil = $oclient->get_utility;
  my $ctx = $outil->{make_context}->({
    'opname' => 'load', 'client' => $oclient, 'utility' => $outil,
  }, undef);

  $oclient->{features} = [];
  my $names = sub { [map { $_->{name} } @{ $oclient->{features} }] };

  $outil->{feature_add}->($ctx, named_feature('a'));
  $outil->{feature_add}->($ctx, named_feature('b'));
  is_deeply($names->(), ['a', 'b'], 'feature_add base order');

  my $before = named_feature('z1');
  $before->{_options} = { '__before__' => 'b' };
  $outil->{feature_add}->($ctx, $before);
  is_deeply($names->(), ['a', 'z1', 'b'], 'feature_add __before__');

  my $after = named_feature('z2');
  $after->{_options} = { '__after__' => 'a' };
  $outil->{feature_add}->($ctx, $after);
  is_deeply($names->(), ['a', 'z2', 'z1', 'b'], 'feature_add __after__');

  my $replace = named_feature('z3');
  $replace->{_options} = { '__replace__' => 'z1' };
  $outil->{feature_add}->($ctx, $replace);
  is_deeply($names->(), ['a', 'z2', 'z3', 'b'], 'feature_add __replace__');

  # An ordering option naming no existing feature falls back to append.
  my $miss = named_feature('z4');
  $miss->{_options} = { '__before__' => 'missing' };
  $outil->{feature_add}->($ctx, $miss);
  is_deeply($names->(), ['a', 'z2', 'z3', 'b', 'z4'], 'feature_add missing target appends');
}


# === feature order ===

{
  # make_options resolves the feature add-order into
  # __derived__.featureorder: a map defaults test-first (so the test mock is
  # the base transport), an explicit array preserves the developer order, and
  # a map without test is deterministic (names sorted).
  my $resolve = sub {
    my ($feature) = @_;
    my $ctx = $utility->{make_context}->({
      'client' => $client, 'utility' => $utility,
    }, undef);
    $ctx->{options} = { 'feature' => $feature };
    $ctx->{config} = { 'options' => {} };
    return $utility->{make_options}->($ctx);
  };

  my $o1 = $resolve->({
    'metrics' => { 'active' => Voxgig::Struct::JTRUE() },
    'test' => { 'active' => Voxgig::Struct::JTRUE() },
  });
  is(join(',', @{ $o1->{__derived__}{featureorder} }), 'test,metrics',
    'feature order: map form is ordered test-first');

  my $o2 = $resolve->([
    { 'name' => 'metrics', 'active' => Voxgig::Struct::JTRUE() },
    { 'name' => 'test', 'active' => Voxgig::Struct::JTRUE() },
  ]);
  is(join(',', @{ $o2->{__derived__}{featureorder} }), 'metrics,test',
    'feature order: array form preserves the explicit developer order');
  ok(UnivecHelpers::is_true($o2->{feature}{metrics}{active}),
    'feature order: array normalized to a map (metrics opts preserved)');
  ok(UnivecHelpers::is_true($o2->{feature}{test}{active}),
    'feature order: array normalized to a map (test opts preserved)');

  my $o3 = $resolve->({
    'retry' => { 'active' => Voxgig::Struct::JTRUE() },
    'cache' => { 'active' => Voxgig::Struct::JTRUE() },
  });
  is(join(',', @{ $o3->{__derived__}{featureorder} }), 'cache,retry',
    'feature order: map form with no test orders names deterministically');
}


# === prepare_auth ===

# A cookie credential as prepare_auth writes it: `<scheme>=K` for the probe
# key, with no scheme prefix and nothing else in the bag.
sub _is_cookie_pair {
  my ($value) = @_;
  return (defined $value && !ref $value && $value =~ m{^[^=;]+=K$}) ? 1 : 0;
}

sub auth_ctx {
  my ($options, $spec) = @_;
  my $ctx = UnivecContext->new({
    'client' => PipelineOptClient->new($options),
    'utility' => $utility,
    'opname' => 'load',
  }, undef);
  $ctx->{spec} = $spec;
  return $ctx;
}

sub auth_bags {
  return UnivecSpec->new({ 'headers' => {}, 'query' => {}, 'step' => 's' });
}

# A cookie credential rides the header bag, because a cookie IS a header.
sub auth_bag {
  my ($spec, $where) = @_;
  return 'query' eq $where ? $spec->{query} : $spec->{headers};
}

# `basic: false` is explicit: an HTTP Basic API's generated config carries
# `auth.basic: true`, and a client that merges it in takes a branch that needs
# a secret as well. With none supplied that branch deliberately writes
# nothing, which the probe would read as a public API.
sub auth_block {
  my ($prefix) = @_;
  return { 'prefix' => $prefix, 'basic' => 0 };
}

# Run prepare_auth with both containers present and see which one the
# generated utility writes to, and under what name. undef means this SDK
# places no credential at all - a public API - which is a legitimate shape,
# and the tests below assert exactly that instead. `pair` is the `<scheme>=`
# lead-in of a COOKIE credential, which rides the header bag under the key
# `cookie` instead of taking a header of its own.
sub auth_probe {
  my ($options) = @_;
  my $ctx = auth_ctx($options, auth_bags());
  $utility->{prepare_auth}->($ctx);
  for my $where ('headers', 'query') {
    my $bag = auth_bag($ctx->{spec}, $where);
    for my $name (keys %{ $bag || {} }) {
      my $value = $bag->{$name};
      my $pair = '';
      if ('headers' eq $where && 'cookie' eq $name && _is_cookie_pair($value)) {
        $pair = substr($value, 0, -1);
      }
      return { 'where' => $where, 'name' => $name,
        'value' => $value, 'pair' => $pair };
    }
  }
  return undef;
}

sub auth_credential {
  return auth_probe({ 'apikey' => 'K', 'auth' => auth_block('Bearer') });
}

# Every credential this SDK could possibly place: both credentials and Basic
# switched on, so whichever branch the API has, something lands unless the API
# is public.
sub auth_any_credential {
  return auth_probe({ 'apikey' => 'K', 'secret' => 'S',
    'auth' => { 'prefix' => 'Bearer', 'basic' => 1 } });
}

# Returns the value left in the credential slot, and whether it is there.
sub auth_placed {
  my ($options, $seed) = @_;
  my $cred = auth_credential();
  my $spec = auth_bags();
  if (defined $cred && defined $seed) {
    # Seed what prepare_auth would have written: pair is the "<scheme>="
    # lead-in for a cookie and '' for a header or query credential.
    auth_bag($spec, $cred->{where})->{ $cred->{name} } = $cred->{pair} . $seed;
  }
  my $ctx = auth_ctx($options, $spec);
  $utility->{prepare_auth}->($ctx);
  return (undef, 0) if !defined $cred;
  my $bag = auth_bag($ctx->{spec}, $cred->{where});
  return ($bag->{ $cred->{name} }, exists $bag->{ $cred->{name} } ? 1 : 0);
}

{
  my $ctx = auth_ctx({ 'auth' => auth_block(''), 'apikey' => 'K' }, undef);
  my (undef, $err) = $utility->{prepare_auth}->($ctx);
  is($err->{code}, 'auth_no_spec', 'prepare_auth guards a missing spec');
}

# Without this the cases below cannot fail for an SDK whose credential the
# probe misses: every one of them takes the public-API path instead.
{
  is(defined auth_credential() ? 1 : 0, defined auth_any_credential() ? 1 : 0,
    'prepare_auth probe finds the credential this SDK places');
}

{
  my $cred = auth_credential();
  if (!defined $cred) {
    # A public API places nothing, and that is the whole assertion.
    my (undef, $has) =
      auth_placed({ 'apikey' => 'K', 'auth' => auth_block('Bearer') });
    ok(!$has, 'prepare_auth places no credential for a public API');
  }
  elsif ('' ne $cred->{pair}) {
    # A cookie credential is a `<scheme>=<key>` pair, and the scheme name
    # leaves no room for the option's prefix.
    ok(_is_cookie_pair($cred->{value}),
      'prepare_auth places the apikey as a cookie pair');
  }
  else {
    ok('headers' eq $cred->{where} || 'query' eq $cred->{where},
      'prepare_auth places the credential in headers or query');
    # A header credential is prefix-joined; a query credential is the raw
    # key, because a query parameter has nowhere to put a scheme name.
    is($cred->{value}, 'query' eq $cred->{where} ? 'K' : 'Bearer K',
      'prepare_auth places the apikey where this API puts it');
  }
}

{
  my ($value, $has) = auth_placed({ 'apikey' => 'K', 'auth' => auth_block('') });
  my $cred = auth_credential();
  if (defined $cred) {
    is($value, $cred->{pair} . 'K', 'prepare_auth a raw apikey goes in as-is');
  }
  else {
    ok(!$has, 'prepare_auth a raw apikey places nothing for a public API');
  }
}

{
  my (undef, $has) =
    auth_placed({ 'apikey' => '', 'auth' => auth_block('Bearer') }, 'stale');
  ok(!$has, 'prepare_auth an empty apikey drops the credential');
}

{
  my (undef, $has) = auth_placed({ 'apikey' => 'K' }, 'stale');
  ok(!$has, 'prepare_auth a public api drops the credential');
}

{
  my (undef, $has) = auth_placed({ 'auth' => auth_block('Bearer') }, 'stale');
  ok(!$has, 'prepare_auth a missing apikey option drops the credential');
}


# === result helpers ===

{
  my $ctx = make_ctx();
  $ctx->{response} = UnivecResponse->new({ 'status' => 200 });
  $ctx->{result} = UnivecResult->new({});
  $utility->{result_headers}->($ctx);
  is_deeply($ctx->{result}{headers}, {},
    'result_headers with non-hash headers yields an empty map');
}

{
  my $ctx = make_ctx();
  $ctx->{response} = UnivecResponse->new({
    'status' => 200, 'json' => sub { { 'a' => 1 } }, 'body' => undef,
  });
  $ctx->{result} = UnivecResult->new({});
  $utility->{result_body}->($ctx);
  ok(!defined $ctx->{result}{body}, 'result_body skips parsing when the body is absent');
}

done_testing();
