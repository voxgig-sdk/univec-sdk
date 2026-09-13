#!perl
# Univec SDK primary utility test
#
# Corpus sections run through the vendored omni runner, via the resolver
# in t/omni.pm (struct-runner shape over native Voxgig::Omni). The inline
# corpus engine this file used to carry is retired: omni resolves
# arguments, applies the null rules, and enforces out/err/match - the
# subjects below only adapt each utility's calling convention.
#
# Three conventions to know when adding a section:
#
# - Subjects receive the contextified entry as a map-face VIEW; unwrap the
#   live blessed context with UnivecOmni::livectx before calling a
#   utility (utilities call methods on it - `$ctx->make_error`).
#
# - Utilities that answer as a (value, err) PAIR go through _unwrap, which
#   dies with the err so omni can match it against `err:` expectations.
#   Utilities that answer bare values (or die) are passed straight in.
#
# - `match: {ctx: ...}` assertions read the LIVE context after the subject
#   ran - the resolver's view presents the context object as the map omni
#   walks, camelCase keys included.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Scalar::Util ();
use File::Basename ();
use Cwd ();

use UnivecSDK;

require(Cwd::abs_path("$FindBin::Bin/omni.pm"));

my $TEST_JSON = Cwd::abs_path("$FindBin::Bin/../../.sdk/test/test.json");

unless (defined $TEST_JSON && -e $TEST_JSON) {
  plan skip_all => 'test.json corpus not found';
}

my $_runner = UnivecOmni::make_runner($TEST_JSON, UnivecSDK->test(undef, undef));
my $_run = $_runner->('primary');

my $spec = $_run->{spec};
my $runset = $_run->{runset};
my $runsetflags = $_run->{runsetflags};

# Under the old inline runner the suite drove the SDK directly; under omni
# the runpack's client is the provider wrapping it. This suite treats the
# client as the SDK - so unwrap the real instance (mirrors ts/py).
my $client = $_run->{client}{sdk};
my $utility = $client->get_utility;

ok(Voxgig::Struct::ismap($spec), 'primary section found in test.json');


# Sections deliberately left empty in the shared corpus
# (.sdk/test/primary/<name>.aon carries a PENDING header). Everything else
# MUST contribute cases.
my %PENDING = map { $_ => 1 } qw(
  fetcher makeFetchDef makeResult featureAdd featureHook featureInit
);


# === Helper packages ===

{
  package TestHookFeature;
  our @ISA = ('UnivecBaseFeature');

  sub new {
    my ($class, $fn) = @_;
    my $self = UnivecBaseFeature::new($class);
    $self->{hook_fn} = $fn;
    return $self;
  }

  sub TestHook {
    my ($self) = @_;
    $self->{hook_fn}->() if $self->{hook_fn};
    return;
  }
}

{
  package TestInitFeature;
  our @ISA = ('UnivecBaseFeature');

  sub new {
    my ($class, $name, $active, $fn) = @_;
    my $self = UnivecBaseFeature::new($class);
    $self->{name} = $name;
    $self->{active} = $active;
    $self->{init_fn} = $fn;
    return $self;
  }

  sub init {
    my ($self) = @_;
    $self->{init_fn}->() if $self->{init_fn};
    return;
  }
}


# === Helpers ===

# Run one corpus section, failing loudly when it would run ZERO cases. A
# renamed section or a fixture that compiled to an empty `set` used to
# pass silently, which defeats the point of a shared oracle. EVERY
# corpus-backed test goes through here (mirrors ts/py). Each section is
# one assertion; omni's failure message carries the entry index, the entry
# and both values.
sub runsection {
  my ($name, $subject) = @_;

  my $section = (ref($spec) eq 'HASH') ? $spec->{$name} : undef;
  unless (ref($section) eq 'HASH') {
    fail("corpus section '$name' missing - check the name against .sdk/test/primary/");
    return;
  }
  my $basic = $section->{basic};
  unless (ref($basic) eq 'HASH' && ref($basic->{set}) eq 'ARRAY') {
    fail("corpus section '$name' has no basic.set list");
    return;
  }
  if (0 == scalar(@{ $basic->{set} }) && !$PENDING{$name}) {
    fail("corpus section '$name' is EMPTY - zero cases would run; add cases, "
      . 'or mark the fixture PENDING in .sdk/test/primary/');
    return;
  }

  my $ok = eval { $runset->($basic, $subject); 1 };
  if ($ok) { pass("$name.basic") }
  else {
    my $err = $@;
    fail("$name.basic");
    diag("$name.basic: $err");
  }
  return;
}

# (value, err) pair convention -> value-or-die, omni's shape.
sub _unwrap {
  my ($val, $err) = @_;
  die $err if defined $err;
  return $val;
}

sub _err_from_map {
  my ($m) = @_;
  return undef unless ref($m) eq 'HASH';
  my $msg = $m->{message};
  return undef unless defined $msg && !ref $msg && '' ne $msg;
  my $code = defined $m->{code} ? $m->{code} : '';
  return UnivecError->new($code, $msg);
}

sub make_test_ctx {
  my ($c, $u, $overrides) = @_;
  my $ctxmap = {
    'opname' => 'load',
    'client' => $c,
    'utility' => $u,
  };
  if ($overrides) {
    $ctxmap->{$_} = $overrides->{$_} for keys %$overrides;
  }
  return $u->{make_context}->($ctxmap, $c->get_root_ctx);
}

sub make_test_full_ctx {
  my ($c, $u) = @_;
  my $ctx = make_test_ctx($c, $u, undef);
  $ctx->{point} = {
    'parts' => ['items', '{id}'],
    'args' => { 'params' => [{ 'name' => 'id', 'reqd' => Voxgig::Struct::JTRUE() }] },
    'params' => ['id'],
    'alias' => {},
    'select' => {},
    'active' => Voxgig::Struct::JTRUE(),
    'transform' => {},
  };
  $ctx->{match} = { 'id' => 'item01' };
  $ctx->{reqmatch} = { 'id' => 'item01' };
  return $ctx;
}

# DEF blocks are read from the LOADED spec, so clone before the in-place
# model conversion.
sub _def_setup {
  my ($name) = @_;
  my $section = (ref($spec) eq 'HASH') ? $spec->{$name} : undef;
  my $setup = (ref($section) eq 'HASH' && ref($section->{DEF}) eq 'HASH'
    && ref($section->{DEF}{setup}) eq 'HASH') ? $section->{DEF}{setup}{a} : undef;
  return undef unless ref($setup) eq 'HASH';
  return UnivecOmni::tostruct(Voxgig::Omni::Util::clone($setup));
}


# === exists ===

for my $name (qw(
  clean done make_error feature_add feature_hook feature_init fetcher
  make_fetch_def make_context make_options make_request make_response
  make_result make_point make_spec make_url param prepare_auth prepare_body
  prepare_headers prepare_method prepare_params prepare_path prepare_query
  result_basic result_body result_headers transform_request transform_response
)) {
  ok(ref $utility->{$name} eq 'CODE', "$name should not be nil");
}


# === clean ===

{
  my $ctx = make_test_ctx($client, $utility, undef);
  my $val = { 'key' => 'secret123', 'name' => 'test' };
  my $cleaned = $utility->{clean}->($ctx, $val);
  ok(defined $cleaned, 'clean basic: cleaned should not be nil');
}


# === done ===

runsection('done', sub {
  my ($view) = @_;
  return $utility->{done}->(UnivecOmni::livectx($view));
});


# === makeError ===

runsection('makeError', sub {
  my ($view, $errmap) = @_;
  my $ctx = UnivecOmni::livectx($view);
  my $err = _err_from_map($errmap);
  # make_error dies with the constructed error on the default (throw)
  # path; omni matches it against the entry's err.
  return $utility->{make_error}->($ctx, $err);
});

{
  my $ctx = make_test_full_ctx($client, $utility);
  $ctx->{ctrl}{throw_err} = 0;
  $ctx->{result} = UnivecResult->new({
    'ok' => 0,
    'resdata' => { 'id' => 'safe01' },
  });

  # Opt-out path: throw_err disabled -> returns the bare result data, no die.
  my $out = $utility->{make_error}->($ctx, $ctx->make_error('test_code', 'test message'));
  ok(Voxgig::Struct::ismap($out), 'make_error no-throw returns hash result');
  is($out->{id}, 'safe01', 'make_error no-throw expected id=safe01');
}


# === featureAdd ===

{
  my $ctx = make_test_ctx($client, $utility, undef);
  my $start_len = scalar @{ $client->{features} };

  my $feature = UnivecBaseFeature->new;
  $utility->{feature_add}->($ctx, $feature);

  is(scalar @{ $client->{features} }, $start_len + 1, 'feature_add basic');
}


# === featureHook ===

{
  my $hook_client = UnivecSDK->test(undef, undef);
  my $hook_utility = $hook_client->get_utility;
  my $ctx = make_test_ctx($hook_client, $hook_utility, undef);

  my $called = 0;
  my $hook_feature = TestHookFeature->new(sub { $called = 1 });
  $hook_client->{features} = [$hook_feature];

  $hook_utility->{feature_hook}->($ctx, 'TestHook');
  ok($called, 'feature_hook basic: expected TestHook to be called');
}


# === featureInit ===

{
  my $init_client = UnivecSDK->test(undef, undef);
  my $init_utility = $init_client->get_utility;
  my $ctx = make_test_ctx($init_client, $init_utility, undef);
  $ctx->{options}{feature} = {
    'initfeat' => { 'active' => Voxgig::Struct::JTRUE() },
  };

  my $init_called = 0;
  my $feature = TestInitFeature->new('initfeat', 1, sub { $init_called = 1 });

  $init_utility->{feature_init}->($ctx, $feature);
  ok($init_called, 'feature_init basic: expected init to be called');
}

{
  my $init_client = UnivecSDK->test(undef, undef);
  my $init_utility = $init_client->get_utility;
  my $ctx = make_test_ctx($init_client, $init_utility, undef);
  $ctx->{options}{feature} = {
    'nofeat' => { 'active' => Voxgig::Struct::JFALSE() },
  };

  my $init_called = 0;
  my $feature = TestInitFeature->new('nofeat', 0, sub { $init_called = 1 });

  $init_utility->{feature_init}->($ctx, $feature);
  ok(!$init_called, 'feature_init inactive: init NOT called for inactive feature');
}


# === fetcher ===

{
  my $calls = [];
  my $live_client = UnivecSDK->new({
    # Concrete base: a live construction must satisfy any server variables
    # a templated base URL declares; a literal base sidesteps the
    # requirement.
    'base' => 'http://localhost:8080',
    'system' => {
      'fetch' => sub {
        my ($url, $fetchdef) = @_;
        push @$calls, { 'url' => $url, 'init' => $fetchdef };
        return ({ 'status' => 200, 'statusText' => 'OK' }, undef);
      },
    },
  });
  my $live_utility = $live_client->get_utility;
  my $ctx = $live_utility->{make_context}->({
    'opname' => 'load',
    'client' => $live_client,
    'utility' => $live_utility,
  }, undef);

  my $fetchdef = { 'method' => 'GET', 'headers' => {} };
  my (undef, $err) = $live_utility->{fetcher}->($ctx, 'http://example.com/test', $fetchdef);
  ok(!defined $err, "fetcher live: expected no error, got: " . (defined $err ? "$err" : ''));
  is(scalar @$calls, 1, 'fetcher live: expected 1 call');
  is($calls->[0]{url}, 'http://example.com/test', 'fetcher live: url passed through');
}

{
  my $blocked_client = UnivecSDK->new({
    'base' => 'http://localhost:8080',
    'system' => {
      'fetch' => sub { return ({}, undef) },
    },
  });
  $blocked_client->{mode} = 'test';

  my $blocked_utility = $blocked_client->get_utility;
  my $ctx = $blocked_utility->{make_context}->({
    'opname' => 'load',
    'client' => $blocked_client,
    'utility' => $blocked_utility,
  }, undef);

  my $fetchdef = { 'method' => 'GET', 'headers' => {} };
  my (undef, $err) = $blocked_utility->{fetcher}->($ctx, 'http://example.com/test', $fetchdef);
  ok(defined $err, 'fetcher blocked: expected error for test mode fetch');
  like("$err", qr/blocked/, 'fetcher blocked: error contains "blocked"');
}


# === makeContext ===

runsection('makeContext', sub {
  my ($vin) = @_;
  return undef unless ref($vin) eq 'HASH';
  my $ctx = $utility->{make_context}->($vin, undef);
  my $out = { 'id' => $ctx->{id} };
  if ($ctx->{op}) {
    $out->{op} = {
      'name' => $ctx->{op}{name},
      'input' => $ctx->{op}{input},
    };
  }
  return $out;
});


# === makeFetchDef ===

{
  my $ctx = make_test_full_ctx($client, $utility);
  $ctx->{spec} = UnivecSpec->new({
    'base' => 'http://localhost:8080',
    'prefix' => '/api',
    'path' => 'items/{id}',
    'suffix' => '',
    'params' => { 'id' => 'item01' },
    'query' => {},
    'headers' => { 'content-type' => 'application/json' },
    'method' => 'GET',
    'step' => 'start',
  });
  $ctx->{result} = UnivecResult->new({});

  my ($fetchdef, $err) = $utility->{make_fetch_def}->($ctx);
  ok(!defined $err, 'make_fetch_def basic: no error');
  is($fetchdef->{method}, 'GET', 'make_fetch_def basic: method');
  like(($fetchdef->{url} || ''), qr{/api/items/item01}, 'make_fetch_def basic: url');
  is($fetchdef->{headers}{'content-type'}, 'application/json',
    'make_fetch_def basic: headers');
  ok(!defined $fetchdef->{body}, 'make_fetch_def basic: nil body');
}

{
  my $ctx = make_test_full_ctx($client, $utility);
  $ctx->{spec} = UnivecSpec->new({
    'base' => 'http://localhost:8080',
    'prefix' => '',
    'path' => 'items',
    'suffix' => '',
    'params' => {},
    'query' => {},
    'headers' => {},
    'method' => 'POST',
    'step' => 'start',
    'body' => { 'name' => 'test' },
  });
  $ctx->{result} = UnivecResult->new({});

  my ($fetchdef, $err) = $utility->{make_fetch_def}->($ctx);
  ok(!defined $err, 'make_fetch_def body: no error');
  is($fetchdef->{method}, 'POST', 'make_fetch_def body: method');
  my $body_str = $fetchdef->{body};
  ok(defined $body_str && !ref $body_str, 'make_fetch_def body: expected body string');
  like($body_str, qr/"name"/, 'make_fetch_def body: body content');
}


# === makeOptions ===

runsection('makeOptions', sub {
  my ($vin) = @_;
  $vin = {} unless ref($vin) eq 'HASH';
  my $ctx = $utility->{make_context}->({
    'options' => $vin->{options},
    'config' => $vin->{config},
  }, undef);
  $ctx->{client} = $client;
  $ctx->{utility} = $utility;
  return $utility->{make_options}->($ctx);
});


# === makeRequest ===

runsection('makeRequest', sub {
  my ($view) = @_;
  my $ctx = UnivecOmni::livectx($view);
  $ctx->{options} = $client->options_map;
  return _unwrap($utility->{make_request}->($ctx));
});


# === makeResponse ===

runsection('makeResponse', sub {
  my ($view) = @_;
  return _unwrap($utility->{make_response}->(UnivecOmni::livectx($view)));
});


# === makeResult ===

{
  my $ctx = make_test_full_ctx($client, $utility);
  $ctx->{spec} = UnivecSpec->new({
    'base' => 'http://localhost:8080',
    'prefix' => '/api',
    'path' => 'items/{id}',
    'suffix' => '',
    'params' => { 'id' => 'item01' },
    'query' => {},
    'headers' => {},
    'method' => 'GET',
    'step' => 'start',
  });
  $ctx->{result} = UnivecResult->new({
    'ok' => 1,
    'status' => 200,
    'statusText' => 'OK',
    'headers' => {},
    'resdata' => { 'id' => 'item01', 'name' => 'Test' },
  });

  my ($result, $err) = $utility->{make_result}->($ctx);
  ok(!defined $err, 'make_result basic: no error');
  is($result->{status}, 200, 'make_result basic: status');
}

{
  my $ctx = make_test_full_ctx($client, $utility);
  $ctx->{spec} = undef;
  $ctx->{result} = UnivecResult->new({
    'ok' => 1, 'status' => 200, 'statusText' => 'OK', 'headers' => {},
  });
  my (undef, $err) = $utility->{make_result}->($ctx);
  ok(defined $err, 'make_result: expected error for nil spec');
}

{
  my $ctx = make_test_full_ctx($client, $utility);
  $ctx->{spec} = UnivecSpec->new({ 'step' => 'start' });
  $ctx->{result} = undef;
  my (undef, $err) = $utility->{make_result}->($ctx);
  ok(defined $err, 'make_result: expected error for nil result');
}


# === makeSpec ===

{
  my $spec_client = UnivecSDK->test(undef, _def_setup('makeSpec'));

  runsection('makeSpec', sub {
    my ($view) = @_;
    my $ctx = UnivecOmni::livectx($view);
    $ctx->{client} = $spec_client;
    $ctx->{options} = $spec_client->options_map;
    return _unwrap($utility->{make_spec}->($ctx));
  });
}


# === makePoint ===

# Driven from the corpus like every other section; the single-point
# sanity case is kept below.
runsection('makePoint', sub {
  my ($view) = @_;
  my ($point, $err) = $utility->{make_point}->(UnivecOmni::livectx($view));
  # The corpus asserts refusals by code (`match: {out: {code: ...}}`), so
  # an error is the RESULT here, flattened to the map the corpus reads.
  return UnivecOmni::errify($err) if defined $err;
  return $point;
});

{
  my $ctx = make_test_ctx($client, $utility, undef);
  my $point = {
    'parts' => ['items', '{id}'],
    'args' => { 'params' => [] },
    'params' => [],
    'alias' => {},
    'select' => {},
    'active' => Voxgig::Struct::JTRUE(),
    'transform' => {},
  };
  $ctx->{op}{points} = [$point];

  my (undef, $err) = $utility->{make_point}->($ctx);
  ok(!defined $err, 'make_point basic: no error');
  ok(defined $ctx->{point}, 'make_point basic: expected point to be set');
}


# === makeUrl ===

runsection('makeUrl', sub {
  my ($view) = @_;
  my $ctx = UnivecOmni::livectx($view);
  $ctx->{result} = UnivecResult->new({}) unless $ctx->{result};
  return _unwrap($utility->{make_url}->($ctx));
});


# === operator ===

runsection('operator', sub {
  my ($vin) = @_;
  $vin = {} unless ref($vin) eq 'HASH';
  my $op = UnivecOperation->new($vin);
  return {
    'entity' => $op->{entity},
    'name' => $op->{name},
    'input' => $op->{input},
    'points' => $op->{points},
  };
});


# === param ===

runsection('param', sub {
  my ($view, $paramdef) = @_;
  return $utility->{param}->(UnivecOmni::livectx($view), $paramdef);
});


# === prepareAuth ===

{
  my $auth_client = UnivecSDK->test(undef, _def_setup('prepareAuth'));

  runsection('prepareAuth', sub {
    my ($view) = @_;
    my $ctx = UnivecOmni::livectx($view);
    $ctx->{client} = $auth_client;
    return _unwrap($utility->{prepare_auth}->($ctx));
  });
}


# === prepareBody ===

runsection('prepareBody', sub {
  my ($view) = @_;
  return $utility->{prepare_body}->(UnivecOmni::livectx($view));
});


# === prepareHeaders ===

runsection('prepareHeaders', sub {
  my ($view) = @_;
  return $utility->{prepare_headers}->(UnivecOmni::livectx($view));
});


# === prepareMethod ===

runsection('prepareMethod', sub {
  my ($view) = @_;
  return $utility->{prepare_method}->(UnivecOmni::livectx($view));
});


# === prepareParams ===

runsection('prepareParams', sub {
  my ($view) = @_;
  return $utility->{prepare_params}->(UnivecOmni::livectx($view));
});


# === preparePath ===

runsection('preparePath', sub {
  my ($view) = @_;
  return $utility->{prepare_path}->(UnivecOmni::livectx($view));
});


# === prepareQuery ===

runsection('prepareQuery', sub {
  my ($view) = @_;
  return $utility->{prepare_query}->(UnivecOmni::livectx($view));
});


# === resultBasic ===

runsection('resultBasic', sub {
  my ($view) = @_;
  my $result = $utility->{result_basic}->(UnivecOmni::livectx($view));

  my $out = {
    'status' => $result->{status},
    'statusText' => $result->{status_text},
  };
  if ($result->{err}) {
    $out->{err} = {
      'message' => '' . $result->{err},
    };
  }
  return $out;
});


# === resultBody ===

runsection('resultBody', sub {
  my ($view) = @_;
  return $utility->{result_body}->(UnivecOmni::livectx($view));
});


# === resultHeaders ===

runsection('resultHeaders', sub {
  my ($view) = @_;
  return $utility->{result_headers}->(UnivecOmni::livectx($view));
});


# === transformRequest ===

runsection('transformRequest', sub {
  my ($view) = @_;
  return $utility->{transform_request}->(UnivecOmni::livectx($view));
});


# === transformResponse ===

runsection('transformResponse', sub {
  my ($view) = @_;
  return $utility->{transform_response}->(UnivecOmni::livectx($view));
});

done_testing();
