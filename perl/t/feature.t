#!perl
# Univec SDK feature test
#
# Behavioural tests for the enterprise features shipped with this SDK.
# Each block runs only when its feature is present (see has_feature),
# driving the real generated feature class through an offline miniature of
# the operation pipeline - the same hook order and short-circuit rules as
# the generated entity operations - against a configurable mock transport.
# All timing goes through an injectable virtual clock, so the suite is
# fully deterministic.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Scalar::Util ();

use UnivecSDK;

# --- Harness ---------------------------------------------------------------

# True when this SDK was generated with the named feature.
sub has_feature {
  my ($name) = @_;
  my $f = UnivecConfig::make_config()->{feature};
  return (Voxgig::Struct::ismap($f) && defined $f->{$name}) ? 1 : 0;
}

sub default_method {
  my ($opname) = @_;
  return 'POST' if 'create' eq $opname;
  return 'PATCH' if 'update' eq $opname;
  return 'DELETE' if 'remove' eq $opname;
  return 'GET';
}

# Build a transport-shaped response hash the pipeline understands.
sub make_response {
  my ($status, $data, $headers) = @_;
  my $h = {};
  for my $k (keys %{ $headers || {} }) {
    $h->{lc $k} = $headers->{$k};
  }
  return {
    'status' => $status,
    'statusText' => ($status < 400 ? 'OK' : 'ERR'),
    'body' => 'not-used',
    'json' => sub { $data },
    'headers' => $h,
  };
}

sub default_server {
  return sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    my $method = uc($fetchdef->{method} || 'GET');
    if ('GET' eq $method) {
      return (make_response(200, { 'ok' => 1, 'method' => $method }), undef);
    }
    return (make_response(200,
      { 'ok' => 1, 'method' => $method, 'echo' => $fetchdef->{body} }), undef);
  };
}

# A recording transport: returns ($server, $calls). The optional reply
# sub maps (n, fetchdef) -> (response, err) tuple.
sub recording_server {
  my ($reply) = @_;
  my $calls = [];
  my $server = sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    push @$calls, { 'url' => $fullurl, 'fetchdef' => $fetchdef };
    if ($reply) {
      return $reply->(scalar(@$calls), $fetchdef);
    }
    return (make_response(200, { 'ok' => 1, 'n' => scalar(@$calls) }), undef);
  };
  return ($server, $calls);
}

# A deterministic virtual clock: now() advances only when sleep(ms) is
# called, so timing-based features can be asserted without real delays.
{
  package HarnessClock;

  sub new { my ($class, $start) = @_; return bless { time => (defined $start ? $start : 0) }, $class }
  sub time { $_[0]->{time} }
  sub now { my ($c) = @_; return sub { $c->{time} } }
  sub sleeper { my ($c) = @_; return sub { $c->{time} += (defined $_[0] ? $_[0] : 0) } }
  sub advance { $_[0]->{time} += $_[1]; return }
}

{
  package HarnessFakeClient;

  sub new {
    my ($class, $options) = @_;
    return bless { features => [], mode => 'test', options => $options }, $class;
  }

  sub options_map {
    my ($self) = @_;
    my $out = Voxgig::Struct::clone($self->{options});
    return Voxgig::Struct::ismap($out) ? $out : {};
  }
}

{
  package HarnessFakeEntity;

  sub new { my ($class, $name) = @_; return bless { name => $name }, $class }
  sub get_name { $_[0]->{name} }
}

# A fake client wired with the given features (in init order) plus a mini
# operation pipeline. $features is a list of { name =>, options => }.
{
  package Harness;

  sub new {
    my ($class, $features, %opt) = @_;
    my $self = bless {
      base => (defined $opt{base} ? $opt{base} : 'http://api.test'),
      headers => ($opt{headers} || {}),
      booted => 0,
    }, $class;

    $self->{utility} = UnivecUtility->new;
    $self->{utility}{fetcher} = $opt{server} || main::default_server();

    $self->{client} = HarnessFakeClient->new({
      'base' => $self->{base}, 'headers' => $self->{headers}, 'feature' => {},
    });

    $self->{rootctx} = $self->{utility}{make_context}->({
      'client' => $self->{client},
      'utility' => $self->{utility},
      'options' => $self->{client}{options},
    }, undef);

    # Instantiate + init the requested features (skipping any not present
    # in this SDK). Features self-gate on options.active.
    for my $fspec (@$features) {
      my $name = $fspec->{name};
      next unless main::has_feature($name);
      my $f = UnivecFeatures::make_feature($name);
      my $fopts = { 'active' => Voxgig::Struct::JTRUE(), %{ $fspec->{options} || {} } };
      $self->{client}{options}{feature}{$name} = $fopts;
      $f->init($self->{rootctx}, $fopts);
      push @{ $self->{client}{features} }, $f;
    }

    return $self;
  }

  sub ready {
    my ($self) = @_;
    return if $self->{booted};
    $self->{booted} = 1;
    $self->{utility}{feature_hook}->($self->{rootctx}, 'PostConstruct');
    return;
  }

  sub feature {
    my ($self, $name) = @_;
    for my $f (@{ $self->{client}{features} }) {
      return $f if $f->get_name eq $name;
    }
    return undef;
  }

  sub track {
    my ($self, $key) = @_;
    return $self->{client}{$key};
  }

  # Run one operation through the mini pipeline (mirrors the generated
  # entity op fragment: hook, short-circuit, make*, hook, ...).
  sub op {
    my ($self, %args) = @_;
    my $opname = defined $args{opname} ? $args{opname} : 'load';
    my $entity = defined $args{entity} ? $args{entity} : 'widget';
    my $method = defined $args{method} ? $args{method} : main::default_method($opname);

    my $ctx = $self->{utility}{make_context}->({
      'opname' => $opname,
      'entity' => HarnessFakeEntity->new($entity),
      'ctrl' => ($args{ctrl} || {}),
    }, $self->{rootctx});

    $self->fire($ctx, 'PostConstructEntity');

    my $out = eval {
      $self->fire($ctx, 'PrePoint');
      if (Scalar::Util::blessed($ctx->{out}{point})
        && $ctx->{out}{point}->isa('UnivecError')) {
        die $ctx->{out}{point};
      }

      $self->fire($ctx, 'PreSpec');
      $ctx->{spec} = UnivecSpec->new({
        'method' => $method,
        'base' => $self->{base},
        'path' => (defined $args{path} ? $args{path} : "/$entity"),
        'params' => {},
        'headers' => { %{ $self->{headers} }, %{ $args{headers} || {} } },
        'query' => ($args{query} || {}),
        'body' => $args{body},
        'step' => 'start',
      });

      $self->fire($ctx, 'PreRequest');
      my $url = $self->build_url($ctx->{spec});
      $ctx->{spec}{url} = $url;

      my $fetchdef = {
        'url' => $url,
        'method' => $ctx->{spec}{method},
        'headers' => $ctx->{spec}{headers},
        'body' => $ctx->{spec}{body},
      };
      my ($fetched, $fetch_err) = $self->{utility}{fetcher}->($ctx, $url, $fetchdef);

      $ctx->{response} = Voxgig::Struct::ismap($fetched)
        ? UnivecResponse->new($fetched) : undef;
      $self->fire($ctx, 'PreResponse');

      $self->populate_result($ctx, $fetched, $fetch_err);
      $self->fire($ctx, 'PreResult');
      $self->fire($ctx, 'PreDone');

      if ($ctx->{result} && $ctx->{result}{ok}) {
        return { 'ok' => 1, 'data' => $ctx->{result}{resdata},
          'result' => $ctx->{result}, 'ctx' => $ctx };
      }
      my $err = ($ctx->{result} && $ctx->{result}{err})
        || $ctx->make_error('op_failed', 'operation failed');
      die $err;
    };
    if (my $err = $@) {
      if (Scalar::Util::blessed($err) && $err->isa('UnivecError')) {
        $ctx->{ctrl}{err} = $err;
        $self->fire($ctx, 'PreUnexpected');
        return { 'ok' => 0, 'error' => $err, 'result' => $ctx->{result}, 'ctx' => $ctx };
      }
      die $err;
    }
    return $out;
  }

  sub fire {
    my ($self, $ctx, $name) = @_;
    $self->{utility}{feature_hook}->($ctx, $name);
    return;
  }

  sub build_url {
    my ($self, $spec) = @_;
    my $q = $spec->{query} || {};
    my @keys = sort grep { defined $q->{$_} } keys %$q;
    my $qs = join('&', map {
      Voxgig::Struct::escurl("$_") . '=' . Voxgig::Struct::escurl("$q->{$_}")
    } @keys);
    return $spec->{base} . $spec->{path} . ('' eq $qs ? '' : "?$qs");
  }

  sub populate_result {
    my ($self, $ctx, $fetched, $fetch_err) = @_;
    my $result = UnivecResult->new({});
    $ctx->{result} = $result;

    if ($fetch_err) {
      $result->{err} = $fetch_err;
      return;
    }
    if (!defined $fetched) {
      $result->{err} = $ctx->make_error('op_no_response', 'response: undefined');
      return;
    }

    my $response = $ctx->{response};
    $result->{status} = $response->{status};
    $result->{status_text} = $response->{status_text};
    my $headers = {};
    if (Voxgig::Struct::ismap($response->{headers})) {
      $headers->{lc "$_"} = $response->{headers}{$_} for keys %{ $response->{headers} };
    }
    $result->{headers} = $headers;
    $result->{body} = $response->{json_func}->() if $response->{json_func};
    $result->{resdata} = $result->{body};

    if ($result->{status} >= 400) {
      $result->{err} = $ctx->make_error('request_status',
        "request: $result->{status}: $result->{status_text}");
    }
    $result->{ok} = 1 if !defined $result->{err};
    return;
  }
}

sub harness {
  my ($features, %opt) = @_;
  return Harness->new($features, %opt);
}

sub fspec {
  my ($name, %options) = @_;
  return { 'name' => $name, 'options' => {%options} };
}

sub drain_stream {
  my ($stream) = @_;
  my @seen;
  while (defined(my $item = $stream->())) {
    push @seen, $item;
  }
  return \@seen;
}

# --- Tests -----------------------------------------------------------------

ok(has_feature('test'), 'at least the test feature is present');


# === netsim ===

if (has_feature('netsim')) {
  {
    my $clock = HarnessClock->new;
    my $h = harness([fspec('netsim', 'latency' => 250, 'sleep' => $clock->sleeper)]);
    my $res = $h->op('ctrl' => { 'explain' => {} });
    ok($res->{ok}, 'netsim fixed latency: op ok');
    is($clock->time, 250, 'netsim fixed latency slept 250');
    is($h->track('_netsim')->{calls}, 1, 'netsim tracked 1 call');
  }

  {
    my $clock = HarnessClock->new;
    my $h = harness([fspec('netsim',
      'latency' => { 'min' => 100, 'max' => 300 }, 'seed' => 7,
      'sleep' => $clock->sleeper)]);
    $h->op;
    ok($clock->time >= 100 && $clock->time < 300,
      'netsim ranged latency samples within range (got ' . $clock->time . ')');
  }

  {
    my $clock = HarnessClock->new;
    my $h = harness([fspec('netsim',
      'latency' => { 'min' => 50, 'max' => 50 }, 'sleep' => $clock->sleeper)]);
    $h->op;
    is($clock->time, 50, 'netsim equal min/max latency is exact');
  }

  {
    my $h = harness([fspec('netsim', 'failTimes' => 2, 'failStatus' => 503)]);
    is($h->op->{result}{status}, 503, 'netsim failTimes: first call 503');
    is($h->op->{result}{status}, 503, 'netsim failTimes: second call 503');
    ok($h->op->{ok}, 'netsim failTimes: third call ok');
  }

  {
    my $h = harness([fspec('netsim', 'failEvery' => 2)]);
    ok($h->op->{ok}, 'netsim failEvery: call 1 ok');
    ok(!$h->op->{ok}, 'netsim failEvery: call 2 fails');
    ok($h->op->{ok}, 'netsim failEvery: call 3 ok');
  }

  {
    my $h = harness([fspec('netsim', 'failRate' => 1, 'seed' => 5)]);
    ok(!$h->op->{ok}, 'netsim failRate with a seed is deterministic');
  }

  {
    my $h = harness([fspec('netsim', 'errorTimes' => 1)]);
    is($h->op->{error}{code}, 'netsim_conn', 'netsim errorTimes yields a connection error');
  }

  {
    my $h = harness([fspec('netsim', 'offline' => 1)]);
    is($h->op->{error}{code}, 'netsim_offline', 'netsim offline fails every call');
  }

  {
    my $h = harness([fspec('netsim', 'rateLimitTimes' => 1, 'retryAfter' => 3)]);
    my $res = $h->op;
    is($res->{result}{status}, 429, 'netsim rateLimitTimes returns 429');
    is($res->{result}{headers}{'retry-after'}, '3', 'netsim rateLimitTimes sets retry-after');
  }

  {
    my $h = harness([fspec('netsim', 'active' => 0)]);
    ok($h->op->{ok}, 'netsim inactive: op ok');
    ok(!defined $h->track('_netsim'), 'netsim inactive does not wrap');
  }
}
else { note('feature "netsim" not present in this SDK') }


# === retry ===

if (has_feature('retry')) {
  if (has_feature('netsim')) {
    my $clock = HarnessClock->new;
    my $h = harness([
      fspec('netsim', 'failTimes' => 2, 'failStatus' => 503),
      fspec('retry', 'retries' => 3, 'minDelay' => 10, 'jitter' => 0,
        'sleep' => $clock->sleeper),
    ]);
    ok($h->op->{ok}, 'retry retries transient failures then succeeds');
    is($h->track('_retry')->{attempts}, 2, 'retry tracked 2 attempts');
  }

  if (has_feature('netsim')) {
    my $clock = HarnessClock->new;
    my $h = harness([
      fspec('netsim', 'failTimes' => 9, 'failStatus' => 500),
      fspec('retry', 'retries' => 2, 'minDelay' => 1, 'jitter' => 0,
        'sleep' => $clock->sleeper),
    ]);
    is($h->op->{result}{status}, 500, 'retry gives up after the budget');
  }

  {
    my ($server, $calls) = recording_server(sub { (make_response(404), undef) });
    my $h = harness([fspec('retry', 'retries' => 3, 'minDelay' => 0, 'jitter' => 0)],
      server => $server);
    $h->op;
    is(scalar @$calls, 1, 'retry does not retry a non-retryable status');
  }

  {
    my $clock = HarnessClock->new;
    my ($server, $calls) = recording_server(sub {
      my ($n) = @_;
      return $n < 3
        ? (undef, UnivecError->new('boom', 'boom'))
        : (make_response(200, { 'ok' => 1 }), undef);
    });
    my $h = harness([fspec('retry',
      'retries' => 2, 'minDelay' => 1, 'jitter' => 0, 'sleep' => $clock->sleeper)],
      server => $server);
    my $res = $h->op;
    ok($res->{ok}, 'retry retries a transport error tuple');
    is(scalar @$calls, 3, 'retry transport error: 3 calls');
  }

  {
    my $clock = HarnessClock->new;
    my ($server, $calls) = recording_server(sub {
      (undef, UnivecError->new('boom', 'boom'));
    });
    my $h = harness([fspec('retry',
      'retries' => 2, 'minDelay' => 1, 'jitter' => 0, 'sleep' => $clock->sleeper)],
      server => $server);
    my $res = $h->op;
    ok(!$res->{ok}, 'retry exhausted transport error surfaces');
    is(scalar @$calls, 3, 'retry exhausted: 3 calls');
  }

  if (has_feature('netsim')) {
    my $clock = HarnessClock->new;
    my $h = harness([
      fspec('netsim', 'rateLimitTimes' => 1, 'retryAfter' => 2),
      fspec('retry', 'retries' => 2, 'minDelay' => 10, 'maxDelay' => 60000,
        'jitter' => 0, 'sleep' => $clock->sleeper),
    ]);
    ok($h->op->{ok}, 'retry honours a server retry-after: op ok');
    is($clock->time, 2000, 'retry honours a server retry-after: waited 2000ms');
  }

  {
    my ($server, $calls) = recording_server(sub { (make_response(503), undef) });
    my $h = harness([fspec('retry', 'active' => 0)], server => $server);
    $h->op;
    is(scalar @$calls, 1, 'retry inactive does not wrap');
  }
}
else { note('feature "retry" not present in this SDK') }


# === timeout ===

if (has_feature('timeout')) {
  {
    my $clock = HarnessClock->new;
    my $sleeper = $clock->sleeper;
    my $server = sub {
      $sleeper->(80);
      return (make_response(200, { 'ok' => 1 }), undef);
    };
    my $h = harness([fspec('timeout', 'ms' => 10, 'now' => $clock->now)],
      server => $server);
    my $res = $h->op;
    is($res->{error}{code}, 'timeout', 'timeout expires a slow request');
    is($h->track('_timeout')->{count}, 1, 'timeout tracked');
  }

  {
    my $clock = HarnessClock->new;
    my $h = harness([fspec('timeout', 'ms' => 1000, 'now' => $clock->now)]);
    ok($h->op->{ok}, 'timeout passes a fast request through');
  }

  {
    my $h = harness([fspec('timeout', 'ms' => 0)]);
    ok($h->op->{ok}, 'timeout ms=0 disables the timeout');
  }

  {
    my $server = sub {
      require Time::HiRes;
      Time::HiRes::sleep(0.05);
      return (make_response(200, { 'ok' => 1 }), undef);
    };
    my $h = harness([fspec('timeout', 'ms' => 10)], server => $server);
    is($h->op->{error}{code}, 'timeout', 'timeout interrupts a hanging transport');
  }

  {
    my $h = harness([fspec('timeout', 'active' => 0)]);
    ok($h->op->{ok}, 'timeout inactive does not wrap');
  }
}
else { note('feature "timeout" not present in this SDK') }


# === ratelimit ===

if (has_feature('ratelimit')) {
  {
    my $clock = HarnessClock->new;
    my $h = harness([fspec('ratelimit',
      'rate' => 1, 'burst' => 2, 'now' => $clock->now, 'sleep' => $clock->sleeper)]);
    $h->op;
    $h->op;
    $h->op;
    is($h->track('_ratelimit')->{throttled}, 1, 'ratelimit throttles once the burst is spent');
    ok($clock->time > 0, 'ratelimit waited');
  }

  {
    my $clock = HarnessClock->new;
    my $h = harness([fspec('ratelimit',
      'rate' => 2, 'now' => $clock->now, 'sleep' => $clock->sleeper)]);
    $h->op;
    $h->op;
    $clock->advance(1000); # refill
    $h->op;
    my $track = $h->track('_ratelimit');
    is(($track ? $track->{throttled} : 0), 0,
      'ratelimit burst defaults to rate and refills over time');
  }

  {
    my $h = harness([fspec('ratelimit', 'active' => 0)]);
    ok($h->op->{ok}, 'ratelimit inactive: op ok');
    ok(!defined $h->track('_ratelimit'), 'ratelimit inactive does not wrap');
  }
}
else { note('feature "ratelimit" not present in this SDK') }


# === cache ===

if (has_feature('cache')) {
  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('cache', 'ttl' => 10000)], server => $server);
    my $a = $h->op('path' => '/w/1');
    my $b = $h->op('path' => '/w/1');
    is(scalar @$calls, 1, 'cache serves a repeated read from cache');
    is_deeply($a->{data}, $b->{data}, 'cache replay data matches');
    is($h->track('_cache')->{hit}, 1, 'cache tracked 1 hit');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('cache')], server => $server);
    $h->op('opname' => 'create', 'path' => '/w');
    $h->op('opname' => 'create', 'path' => '/w');
    is(scalar @$calls, 2, 'cache does not cache non-GET');
  }

  {
    my ($server, $calls) = recording_server(sub { (make_response(500), undef) });
    my $h = harness([fspec('cache')], server => $server);
    $h->op('path' => '/w');
    $h->op('path' => '/w');
    is(scalar @$calls, 2, 'cache does not cache a non-2xx');
    is($h->track('_cache')->{bypass}, 2, 'cache tracked 2 bypasses');
  }

  {
    my $clock = HarnessClock->new;
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('cache', 'ttl' => 1000, 'now' => $clock->now)],
      server => $server);
    $h->op('path' => '/w');
    $clock->advance(1500);
    $h->op('path' => '/w');
    is(scalar @$calls, 2, 'cache refetches after the ttl');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('cache', 'ttl' => 10000, 'max' => 1)], server => $server);
    $h->op('path' => '/a');
    $h->op('path' => '/b'); # evicts /a
    $h->op('path' => '/a'); # miss again
    is(scalar @$calls, 3, 'cache evicts the oldest entry past max');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('cache', 'active' => 0)], server => $server);
    $h->op('path' => '/x');
    $h->op('path' => '/x');
    is(scalar @$calls, 2, 'cache inactive does not wrap');
  }
}
else { note('feature "cache" not present in this SDK') }


# === idempotency ===

if (has_feature('idempotency')) {
  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('idempotency')], server => $server);
    $h->op('opname' => 'create', 'path' => '/w');
    ok(defined $calls->[0]{fetchdef}{headers}{'Idempotency-Key'},
      'idempotency adds a key to mutating ops');
    is($h->track('_idempotency')->{issued}, 1, 'idempotency tracked 1 issued');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('idempotency')], server => $server);
    $h->op('opname' => 'act', 'method' => 'PUT', 'path' => '/w');
    ok(defined $calls->[0]{fetchdef}{headers}{'Idempotency-Key'},
      'idempotency adds a key based on http method');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('idempotency')], server => $server);
    $h->op('path' => '/w/1');
    ok(!defined $calls->[0]{fetchdef}{headers}{'Idempotency-Key'},
      'idempotency leaves reads untouched');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('idempotency', 'header' => 'X-Idem')], server => $server);
    $h->op('opname' => 'create', 'path' => '/w', 'headers' => { 'X-Idem' => 'caller-1' });
    is($calls->[0]{fetchdef}{headers}{'X-Idem'}, 'caller-1',
      'idempotency preserves a caller key and custom header');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('idempotency', 'keygen' => sub { 'K1' })], server => $server);
    $h->op('opname' => 'create', 'path' => '/w');
    is($calls->[0]{fetchdef}{headers}{'Idempotency-Key'}, 'K1',
      'idempotency injected keygen');
  }
}
else { note('feature "idempotency" not present in this SDK') }


# === rbac ===

if (has_feature('rbac')) {
  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('rbac',
      'rules' => { 'widget.remove' => 'admin' }, 'permissions' => [])],
      server => $server);
    my $res = $h->op('opname' => 'remove', 'path' => '/w/1');
    is($res->{error}{code}, 'rbac_denied', 'rbac denies');
    is(scalar @$calls, 0, 'rbac denies before any network call');
    is($h->track('_rbac')->{denied}, 1, 'rbac tracked 1 denial');
  }

  {
    my $h = harness([fspec('rbac',
      'rules' => { 'widget.remove' => 'admin' }, 'permissions' => ['admin'])]);
    ok($h->op('opname' => 'remove', 'path' => '/w/1')->{ok},
      'rbac allows a held permission');
    is($h->track('_rbac')->{allowed}, 1, 'rbac tracked 1 allow');
  }

  {
    my $h = harness([fspec('rbac',
      'rules' => { 'load' => 'read' }, 'permissions' => ['*'])]);
    ok($h->op->{ok}, 'rbac rule by op name and wildcard grant');
  }

  {
    my $allow = harness([fspec('rbac', 'permissions' => [])]);
    ok($allow->op->{ok}, 'rbac no rule allows by default');
    my $deny = harness([fspec('rbac', 'deny' => 1, 'permissions' => [])]);
    is($deny->op->{error}{code}, 'rbac_denied', 'rbac deny=true blocks by default');
  }
}
else { note('feature "rbac" not present in this SDK') }


# === metrics ===

if (has_feature('metrics')) {
  if (has_feature('netsim')) {
    my $h = harness([
      fspec('netsim', 'failTimes' => 1, 'failStatus' => 500),
      fspec('metrics'),
    ]);
    $h->op;
    $h->op;
    $h->op('opname' => 'list');
    my $m = $h->track('_metrics');
    is($m->{total}{count}, 3, 'metrics total count');
    is($m->{total}{ok}, 2, 'metrics total ok');
    is($m->{total}{err}, 1, 'metrics total err');
    is($m->{ops}{'widget.load'}{count}, 2, 'metrics per-op count');
  }

  {
    my $t = 0;
    my $h = harness([fspec('metrics', 'now' => sub { $t += 10 })]);
    $h->op;
    my $m = $h->track('_metrics');
    is($m->{total}{count}, 1, 'metrics injected clock count');
    is($m->{total}{totalMs}, 10, 'metrics injected clock totalMs');
    is($m->{total}{maxMs}, 10, 'metrics injected clock maxMs');
  }
}
else { note('feature "metrics" not present in this SDK') }


# === telemetry ===

if (has_feature('telemetry')) {
  {
    my ($server, $calls) = recording_server();
    my $spans = [];
    my $h = harness([fspec('telemetry', 'exporter' => sub { push @$spans, $_[0] })],
      server => $server);
    my $res = $h->op;
    ok($res->{ok}, 'telemetry op ok');
    my $t = $h->track('_telemetry');
    is(scalar @{ $t->{spans} }, 1, 'telemetry recorded 1 span');
    is(scalar @$spans, 1, 'telemetry exporter invoked');
    my $sent = $calls->[0]{fetchdef}{headers};
    is($sent->{'X-Trace-Id'}, $t->{spans}[0]{traceId}, 'telemetry propagates trace id');
    like($sent->{traceparent}, qr/^00-.+-.+-01$/, 'telemetry traceparent format');
  }

  if (has_feature('netsim')) {
    my $h = harness([
      fspec('netsim', 'failTimes' => 1, 'failStatus' => 500),
      fspec('telemetry'),
    ]);
    $h->op;
    my $t = $h->track('_telemetry');
    ok(!$t->{spans}[0]{ok}, 'telemetry records a failed span on error');
    is($t->{active}, 0, 'telemetry no active spans left');
  }

  {
    my $h = harness([fspec('telemetry',
      'idgen' => sub { "$_[0]-X" }, 'now' => sub { 5 })]);
    $h->op;
    my $span = $h->track('_telemetry')->{spans}[0];
    is($span->{traceId}, 'trace-X', 'telemetry injected idgen');
    is($span->{durationMs}, 0, 'telemetry injected clock duration');
  }
}
else { note('feature "telemetry" not present in this SDK') }


# === debug ===

if (has_feature('debug')) {
  {
    my $seen = [];
    my $h = harness([fspec('debug', 'max' => 1, 'on_entry' => sub { push @$seen, $_[0] })]);
    $h->op('headers' => { 'authorization' => 'Bearer secret' });
    $h->op('opname' => 'list');
    my $entries = $h->track('_debug')->{entries};
    is(scalar @$entries, 1, 'debug ring buffer capped at max');
    is(scalar @$seen, 2, 'debug on_entry saw each op');
    is($seen->[0]{headers}{authorization}, '<redacted>', 'debug redacts authorization');
  }

  if (has_feature('netsim')) {
    my $h = harness([
      fspec('netsim', 'failTimes' => 1, 'failStatus' => 500),
      fspec('debug'),
    ]);
    $h->op;
    my $entry = $h->track('_debug')->{entries}[0];
    ok(!$entry->{ok}, 'debug captures failures: not ok');
    is($entry->{status}, 500, 'debug captures failures: status');
  }

  {
    my $h = harness([fspec('debug', 'now' => sub { 7 }, 'redact' => ['x-secret'])]);
    $h->op('headers' => { 'x-secret' => 'hide', 'x-ok' => 'show' });
    my $entry = $h->track('_debug')->{entries}[0];
    is($entry->{headers}{'x-secret'}, '<redacted>', 'debug custom redact');
    is($entry->{headers}{'x-ok'}, 'show', 'debug leaves other headers');
  }
}
else { note('feature "debug" not present in this SDK') }


# === audit ===

if (has_feature('audit')) {
  if (has_feature('netsim')) {
    my $sink = [];
    my $h = harness([
      fspec('netsim', 'failTimes' => 1, 'failStatus' => 500),
      fspec('audit', 'actor' => 'svc', 'sink' => sub { push @$sink, $_[0] }, 'max' => 5),
    ]);
    $h->op('opname' => 'remove', 'path' => '/w/1');
    $h->op('ctrl' => { 'actor' => 'per-call' });
    my $recs = $h->track('_audit')->{records};
    is(scalar @$recs, 2, 'audit one record per op');
    is($recs->[0]{outcome}, 'error', 'audit first outcome error');
    is($recs->[0]{actor}, 'svc', 'audit options actor');
    is($recs->[1]{actor}, 'per-call', 'audit per-call ctrl actor');
    is($recs->[1]{outcome}, 'ok', 'audit second outcome ok');
    is(scalar @$sink, 2, 'audit sink saw both records');
  }

  {
    my $h = harness([fspec('audit', 'now' => sub { 42 })]);
    $h->op;
    my $rec = $h->track('_audit')->{records}[0];
    is($rec->{actor}, 'anonymous', 'audit default actor');
    is($rec->{ts}, 42, 'audit injected clock');
  }

  {
    my $h = harness([fspec('audit', 'max' => 2)]);
    $h->op;
    $h->op;
    $h->op;
    my $recs = $h->track('_audit')->{records};
    is(scalar @$recs, 2, 'audit bounds the record list');
    is_deeply([map { $_->{seq} } @$recs], [2, 3], 'audit keeps the newest records');
  }
}
else { note('feature "audit" not present in this SDK') }


# === clienttrack ===

if (has_feature('clienttrack')) {
  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('clienttrack',
      'clientName' => 'Acme', 'clientVersion' => '2.0.0')], server => $server);
    $h->ready;
    $h->op;
    $h->op;
    my $h0 = $calls->[0]{fetchdef}{headers};
    my $h1 = $calls->[1]{fetchdef}{headers};
    is($h0->{'User-Agent'}, 'Acme/2.0.0', 'clienttrack UA');
    is($h0->{'X-Client-Id'}, $h1->{'X-Client-Id'}, 'clienttrack stable client id');
    isnt($h0->{'X-Request-Id'}, $h1->{'X-Request-Id'}, 'clienttrack unique request ids');
    is($h->track('_clienttrack')->{requests}, 2, 'clienttrack tracked 2 requests');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('clienttrack')], server => $server);
    $h->ready;
    $h->op('headers' => { 'User-Agent' => 'mine' });
    is($calls->[0]{fetchdef}{headers}{'User-Agent'}, 'mine',
      'clienttrack does not clobber a caller user-agent');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('clienttrack',
      'sessionId' => 'S1', 'idgen' => sub { "$_[0]-1" })], server => $server);
    $h->ready;
    $h->op;
    is($calls->[0]{fetchdef}{headers}{'X-Client-Id'}, 'S1', 'clienttrack fixed session');
    is($calls->[0]{fetchdef}{headers}{'X-Request-Id'}, 'request-1',
      'clienttrack injected idgen');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('clienttrack')], server => $server);
    # no ready() -> PreRequest lazily creates the session id
    $h->op;
    ok(defined $calls->[0]{fetchdef}{headers}{'X-Client-Id'},
      'clienttrack lazily creates the session id');
  }
}
else { note('feature "clienttrack" not present in this SDK') }


# === paging ===

if (has_feature('paging')) {
  {
    my ($server, $calls) = recording_server(sub {
      (make_response(200, { 'items' => [1, 2] }, {
        'x-next-page' => '2', 'x-total-count' => '5',
        'link' => '</w?page=2>; rel="next"',
      }), undef);
    });
    my $h = harness([fspec('paging', 'limit' => 2)], server => $server);
    my $res = $h->op('opname' => 'list', 'path' => '/w');
    like($calls->[0]{url}, qr/[?&]page=1(&|$)/, 'paging stamps page');
    like($calls->[0]{url}, qr/[?&]limit=2(&|$)/, 'paging stamps limit');
    my $paging = $res->{result}{paging};
    is($paging->{nextPage}, 2, 'paging nextPage');
    is($paging->{totalCount}, 5, 'paging totalCount');
    is($paging->{next}, '/w?page=2', 'paging link next');
    ok($paging->{hasMore}, 'paging hasMore');
  }

  {
    my ($server, $calls) = recording_server(sub {
      (make_response(200, { 'nextCursor' => 'abc', 'hasMore' => Voxgig::Struct::JTRUE() }), undef);
    });
    my $h = harness([fspec('paging')], server => $server);
    my $res = $h->op('opname' => 'list', 'path' => '/w',
      'ctrl' => { 'paging' => { 'cursor' => 'xyz' } });
    like($calls->[0]{url}, qr/[?&]cursor=xyz(&|$)/, 'paging explicit cursor request');
    is($res->{result}{paging}{cursor}, 'abc', 'paging body cursor');
    ok($res->{result}{paging}{hasMore}, 'paging body hasMore');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('paging')], server => $server);
    my $res = $h->op('path' => '/w/1');
    unlike($calls->[0]{url}, qr/[?&]page=/, 'paging non-list op not paged (url)');
    ok(!defined $res->{result}{paging}, 'paging non-list op not paged (result)');
  }
}
else { note('feature "paging" not present in this SDK') }


# === streaming ===

if (has_feature('streaming')) {
  {
    my $clock = HarnessClock->new;
    my ($server, $calls) = recording_server(sub {
      (make_response(200, ['a', 'b', 'c']), undef);
    });
    my $h = harness([fspec('streaming',
      'chunkDelay' => 5, 'sleep' => $clock->sleeper)], server => $server);
    my $res = $h->op('opname' => 'list', 'path' => '/w');
    ok($res->{result}{streaming}, 'streaming flag set');
    my $seen = drain_stream($res->{result}{stream});
    is_deeply($seen, ['a', 'b', 'c'], 'streaming streams list items');
    is($clock->time, 15, 'streaming chunkDelay per item');
    is($h->track('_streaming')->{opened}, 1, 'streaming tracked 1 open');
  }

  {
    my ($server, $calls) = recording_server(sub {
      (make_response(200, [1, 2, 3, 4, 5]), undef);
    });
    my $h = harness([fspec('streaming', 'chunkSize' => 2)], server => $server);
    my $res = $h->op('opname' => 'list', 'path' => '/w');
    is_deeply(drain_stream($res->{result}{stream}), [[1, 2], [3, 4], [5]],
      'streaming batches with chunkSize');
  }

  {
    my $h = harness([fspec('streaming')]);
    my $res = $h->op;
    ok(!defined $res->{result}{streaming}, 'streaming non-list op is not streamed');
  }
}
else { note('feature "streaming" not present in this SDK') }


# === proxy ===

if (has_feature('proxy')) {
  {
    my ($server, $calls) = recording_server();
    my $agent_url;
    my $h = harness([fspec('proxy',
      'url' => 'http://proxy:8080',
      'agent' => sub { $agent_url = $_[0]; return { 'a' => 1 } })], server => $server);
    $h->op;
    is($calls->[0]{fetchdef}{proxy}, 'http://proxy:8080', 'proxy routes');
    is_deeply($calls->[0]{fetchdef}{dispatcher}, { 'a' => 1 }, 'proxy agent factory used');
    is($agent_url, 'http://proxy:8080', 'proxy agent factory got proxy url');
    is($h->track('_proxy')->{routed}, 1, 'proxy tracked 1 routed');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('proxy',
      'url' => 'http://proxy:8080', 'noProxy' => ['api.test'])],
      server => $server, base => 'http://api.test');
    $h->op;
    ok(!defined $calls->[0]{fetchdef}{proxy}, 'proxy bypasses noProxy hosts');
  }

  {
    local $ENV{HTTPS_PROXY} = 'http://env-proxy:8080';
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('proxy', 'fromEnv' => 1)], server => $server);
    $h->op;
    is($calls->[0]{fetchdef}{proxy}, 'http://env-proxy:8080',
      'proxy fromEnv reads HTTPS_PROXY');
  }

  {
    my ($server, $calls) = recording_server();
    my $h = harness([fspec('proxy', 'active' => 0)], server => $server);
    $h->op;
    ok(!defined $calls->[0]{fetchdef}{proxy}, 'proxy inactive is a no-op');

    my ($server2, $calls2) = recording_server();
    local %ENV = %ENV;
    delete @ENV{qw(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy)};
    my $h2 = harness([fspec('proxy')], server => $server2);
    $h2->op;
    ok(!defined $calls2->[0]{fetchdef}{proxy}, 'proxy without url is a no-op');
  }
}
else { note('feature "proxy" not present in this SDK') }


# === composition ===

if (has_feature('cache') && has_feature('netsim')) {
  my $h = harness([
    fspec('netsim', 'failEvery' => 2),
    fspec('cache', 'ttl' => 10000),
  ]);
  ok($h->op('path' => '/w')->{ok}, 'cache+netsim first call ok');
  ok($h->op('path' => '/w')->{ok}, 'cache+netsim hit skips the simulated failure');
  is($h->track('_netsim')->{calls}, 1, 'cache+netsim only 1 transport call');
}

done_testing();
