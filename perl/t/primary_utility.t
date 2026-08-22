#!perl
# Univec SDK primary utility test
#
# Drives the primary utility test corpus (.sdk/test/test.json "primary")
# through the client's utility view, mirroring the rb primary_utility_test.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Scalar::Util ();
use File::Basename ();
use Cwd ();

use UnivecSDK;

my $TEST_JSON = Cwd::abs_path("$FindBin::Bin/../../.sdk/test/test.json");

unless (defined $TEST_JSON && -e $TEST_JSON) {
  plan skip_all => 'test.json corpus not found';
}

my $SPEC = do {
  open my $fh, '<:raw', $TEST_JSON or die "Cannot open $TEST_JSON: $!";
  local $/;
  Voxgig::Struct::parse_json(<$fh>);
};
my $PRIMARY = get_spec($SPEC, 'primary');
ok(Voxgig::Struct::ismap($PRIMARY), 'primary section found in test.json');

my $client = UnivecSDK->test(undef, undef);
my $utility = $client->get_utility;


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

sub get_spec {
  my ($spec, @keys) = @_;
  my $cur = $spec;
  for my $key (@keys) {
    return undef unless Voxgig::Struct::ismap($cur);
    $cur = $cur->{$key};
  }
  return Voxgig::Struct::ismap($cur) ? $cur : undef;
}

sub canon {
  my ($v) = @_;
  return Voxgig::Struct::_stringify_inner($v, 1);
}

sub match_string {
  my ($pattern, $val) = @_;
  if (length($pattern) >= 2 && '/' eq substr($pattern, 0, 1)
    && '/' eq substr($pattern, -1)) {
    my $re = substr($pattern, 1, length($pattern) - 2);
    return ("$val" =~ /$re/) ? 1 : 0;
  }
  return (index(lc "$val", lc $pattern) >= 0) ? 1 : 0;
}

sub match_deep {
  my ($label, $check, $base, $path) = @_;
  return 1 unless defined $check;

  if (Voxgig::Struct::ismap($check)) {
    for my $key (keys %$check) {
      my $base_val = Voxgig::Struct::ismap($base) ? $base->{$key} : undef;
      return 0 unless match_deep($label, $check->{$key}, $base_val, "$path.$key");
    }
    return 1;
  }
  if (Voxgig::Struct::islist($check)) {
    for my $ci (0 .. $#$check) {
      my $base_val = (Voxgig::Struct::islist($base) && $ci < @$base)
        ? $base->[$ci] : undef;
      return 0 unless match_deep($label, $check->[$ci], $base_val, "$path\[$ci\]");
    }
    return 1;
  }

  if (defined $check && !ref $check && '__EXISTS__' eq $check) {
    return 1 if defined $base;
    fail("$label: match $path: expected value to exist but got undef");
    return 0;
  }
  if (defined $check && !ref $check && '__UNDEF__' eq $check) {
    return 1 if !defined $base;
    fail("$label: match $path: expected undef but got " . canon($base));
    return 0;
  }

  return 1 if canon($check) eq canon($base);

  if (defined $check && !ref($check) && !Voxgig::Struct::is_jbool($check)
    && !Voxgig::Struct::is_jnull($check) && '' ne "$check") {
    my $base_str = defined $base ? "$base" : '';
    return 1 if match_string("$check", $base_str);
  }

  fail("$label: match $path: got " . canon($base) . ', want ' . canon($check));
  return 0;
}

# Run each entry of a test set through $subject (called with the entry;
# returns the result and may die). Expected errors are matched by
# substring / regex; "match" clauses are checked over {in,out,args,ctx}.
sub runset {
  my ($label, $testspec, $subject) = @_;
  unless ($testspec) {
    pass("$label: no test set");
    return;
  }
  my $set = $testspec->{set};
  unless (Voxgig::Struct::islist($set)) {
    pass("$label: empty test set");
    return;
  }

  my $i = -1;
  for my $entry (@$set) {
    $i++;
    next unless Voxgig::Struct::ismap($entry);
    my $mark = defined $entry->{mark} ? " (mark=$entry->{mark})" : '';
    my $elabel = "$label entry $i$mark";

    my $result = eval { $subject->($entry) };
    my $err = $@;

    my $expected_err = $entry->{err};

    if ($err) {
      if (defined $expected_err) {
        my $err_msg = "$err";
        if (!ref $expected_err && !Voxgig::Struct::is_jbool($expected_err)) {
          unless (match_string("$expected_err", $err_msg)) {
            fail("$elabel: error mismatch: got [$err_msg], want contains [$expected_err]");
            next;
          }
        }
        # err: true means any error is acceptable
        if (Voxgig::Struct::ismap($entry->{match})) {
          my $result_map = {
            'in' => $entry->{in},
            'out' => undef,
            'err' => { 'message' => "$err" },
          };
          $result_map->{ctx} = $entry->{ctx} if defined $entry->{ctx};
          next unless match_deep($elabel, $entry->{match}, $result_map, '');
        }
        pass($elabel);
        next;
      }
      fail("$elabel: unexpected error: $err");
      next;
    }

    if (defined $expected_err) {
      fail("$elabel: expected error containing " . canon($expected_err)
        . ' but got result: ' . canon($result));
      next;
    }

    my $matched = 0;
    if (Voxgig::Struct::ismap($entry->{match})) {
      my $result_map = {
        'in' => $entry->{in},
        'out' => $result,
      };
      if (defined $entry->{args}) {
        $result_map->{args} = $entry->{args};
      }
      elsif (defined $entry->{in}) {
        $result_map->{args} = [$entry->{in}];
      }
      $result_map->{ctx} = $entry->{ctx} if defined $entry->{ctx};
      next unless match_deep($elabel, $entry->{match}, $result_map, '');
      $matched = 1;
    }

    my $has_out = exists $entry->{out}
      && defined $entry->{out} && !Voxgig::Struct::is_jnull($entry->{out});
    if (!$has_out && $matched) {
      pass($elabel);
      next;
    }

    if ($has_out) {
      unless (canon($result) eq canon($entry->{out})) {
        fail("$elabel: output mismatch:\n  got:  " . canon($result)
          . "\n  want: " . canon($entry->{out}));
        next;
      }
    }

    pass($elabel);
  }
  return;
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

sub make_ctx_from_map {
  my ($ctxmap, $c, $u) = @_;
  $ctxmap = {} unless Voxgig::Struct::ismap($ctxmap);

  my $ctx = UnivecContext->new($ctxmap, undef);

  if ($c) {
    $ctx->{client} = $c;
    $ctx->{utility} = $u;
  }
  if (!defined $ctx->{options} && $c) {
    $ctx->{options} = $c->options_map;
  }

  # Handle spec from JSON map
  if (Voxgig::Struct::ismap($ctxmap->{spec})) {
    $ctx->{spec} = UnivecSpec->new($ctxmap->{spec});
  }

  # Handle result from JSON map
  if (Voxgig::Struct::ismap($ctxmap->{result})) {
    my $res_map = $ctxmap->{result};
    $ctx->{result} = UnivecResult->new($res_map);
    if (Voxgig::Struct::ismap($res_map->{err})
      && defined $res_map->{err}{message} && !ref $res_map->{err}{message}) {
      $ctx->{result}{err} = UnivecError->new('', $res_map->{err}{message});
    }
  }

  # Handle response from JSON map
  if (Voxgig::Struct::ismap($ctxmap->{response})) {
    my $resp_map = $ctxmap->{response};
    $ctx->{response} = UnivecResponse->new($resp_map);
    if (UnivecHelpers::rb_truthy($resp_map->{body})) {
      my $body_copy = $resp_map->{body};
      $ctx->{response}{json_func} = sub { $body_copy };
    }
    if (Voxgig::Struct::ismap($resp_map->{headers})) {
      my $lower = {};
      $lower->{lc $_} = $resp_map->{headers}{$_} for keys %{ $resp_map->{headers} };
      $ctx->{response}{headers} = $lower;
    }
  }

  return $ctx;
}

sub fixctx {
  my ($ctx, $c) = @_;
  if ($ctx && $ctx->{client} && !defined $ctx->{options}) {
    $ctx->{options} = $ctx->{client}->options_map;
  }
  return;
}

sub err_from_map {
  my ($m) = @_;
  return undef unless Voxgig::Struct::ismap($m);
  my $msg = $m->{message};
  return undef unless defined $msg && !ref $msg && '' ne $msg;
  my $code = defined $m->{code} ? $m->{code} : '';
  return UnivecError->new($code, $msg);
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

runset('done.basic', get_spec($PRIMARY, 'done', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  fixctx($ctx, $client);
  return $utility->{done}->($ctx);
});


# === makeError ===

runset('makeError.basic', get_spec($PRIMARY, 'makeError', 'basic'), sub {
  my ($entry) = @_;
  my $args = $entry->{args} || [{}];

  my $ctxmap = Voxgig::Struct::ismap($args->[0]) ? $args->[0] : {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  fixctx($ctx, $client);

  my $err;
  if (@$args > 1 && Voxgig::Struct::ismap($args->[1])) {
    $err = err_from_map($args->[1]);
  }

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

runset('makeContext.basic', get_spec($PRIMARY, 'makeContext', 'basic'), sub {
  my ($entry) = @_;
  my $in_val = $entry->{in};
  return undef unless Voxgig::Struct::ismap($in_val);
  my $ctx = $utility->{make_context}->($in_val, undef);
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

runset('makeOptions.basic', get_spec($PRIMARY, 'makeOptions', 'basic'), sub {
  my ($entry) = @_;
  my $in_val = $entry->{in} || {};
  my $ctx = $utility->{make_context}->({
    'options' => $in_val->{options},
    'config' => $in_val->{config},
  }, undef);
  $ctx->{client} = $client;
  $ctx->{utility} = $utility;
  return $utility->{make_options}->($ctx);
});


# === makeRequest ===

runset('makeRequest.basic', get_spec($PRIMARY, 'makeRequest', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  $ctx->{options} = $client->options_map;

  my (undef, $err) = $utility->{make_request}->($ctx);
  die $err if $err;

  # Update entry ctx for match checking
  my $entry_ctx = $entry->{ctx};
  if (Voxgig::Struct::ismap($entry_ctx)) {
    $entry_ctx->{response} = 'exists' if $ctx->{response};
    $entry_ctx->{result} = 'exists' if $ctx->{result};
  }

  return undef;
});


# === makeResponse ===

runset('makeResponse.basic', get_spec($PRIMARY, 'makeResponse', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  fixctx($ctx, $client);

  my (undef, $err) = $utility->{make_response}->($ctx);
  die $err if $err;

  # Update entry ctx for match checking with result data
  my $entry_ctx = $entry->{ctx};
  if (Voxgig::Struct::ismap($entry_ctx) && $ctx->{result}) {
    $entry_ctx->{result} = {
      'ok' => Voxgig::Struct::jbool($ctx->{result}{ok} ? 1 : 0),
      'status' => $ctx->{result}{status},
      'statusText' => $ctx->{result}{status_text},
      'headers' => $ctx->{result}{headers},
      'body' => $ctx->{result}{body},
    };
  }

  return undef;
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
  my $setup_opts = get_spec($PRIMARY, 'makeSpec', 'DEF', 'setup', 'a');
  my $spec_client = UnivecSDK->test(undef, $setup_opts);
  my $spec_utility = $spec_client->get_utility;

  runset('makeSpec.basic', get_spec($PRIMARY, 'makeSpec', 'basic'), sub {
    my ($entry) = @_;
    my $ctxmap = $entry->{ctx} || {};
    my $ctx = make_ctx_from_map($ctxmap, $spec_client, $spec_utility);
    $ctx->{options} = $spec_client->options_map;

    my (undef, $err) = $utility->{make_spec}->($ctx);
    die $err if $err;

    # Update entry ctx for match
    my $entry_ctx = $entry->{ctx};
    if (Voxgig::Struct::ismap($entry_ctx) && $ctx->{spec}) {
      $entry_ctx->{spec} = {
        'base' => $ctx->{spec}{base},
        'prefix' => $ctx->{spec}{prefix},
        'suffix' => $ctx->{spec}{suffix},
        'method' => $ctx->{spec}{method},
        'params' => $ctx->{spec}{params},
        'query' => $ctx->{spec}{query},
        'headers' => $ctx->{spec}{headers},
        'step' => $ctx->{spec}{step},
      };
    }

    return undef;
  });
}


# === makePoint ===

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

runset('makeUrl.basic', get_spec($PRIMARY, 'makeUrl', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  $ctx->{result} = UnivecResult->new({}) unless $ctx->{result};
  my ($url, $err) = $utility->{make_url}->($ctx);
  die $err if $err;
  return $url;
});


# === operator ===

runset('operator.basic', get_spec($PRIMARY, 'operator', 'basic'), sub {
  my ($entry) = @_;
  my $in_val = $entry->{in} || {};
  my $op = UnivecOperation->new($in_val);
  return {
    'entity' => $op->{entity},
    'name' => $op->{name},
    'input' => $op->{input},
    'points' => $op->{points},
  };
});


# === param ===

runset('param.basic', get_spec($PRIMARY, 'param', 'basic'), sub {
  my ($entry) = @_;
  my $args = $entry->{args} || [];
  return undef if @$args < 2;

  my $ctxmap = Voxgig::Struct::ismap($args->[0]) ? $args->[0] : {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  my $paramdef = $args->[1];

  my $result = $utility->{param}->($ctx, $paramdef);

  # Update entry ctx for match
  if (Voxgig::Struct::ismap($entry->{match})) {
    my $ctx_match = $entry->{match}{ctx};
    if (Voxgig::Struct::ismap($ctx_match)) {
      my $entry_ctx = $entry->{ctx};
      if (!defined $entry_ctx) {
        $entry_ctx = {};
        $entry->{ctx} = $entry_ctx;
      }
      my $spec_match = $ctx_match->{spec};
      if (Voxgig::Struct::ismap($spec_match) && $ctx->{spec}) {
        $entry_ctx->{spec} = {} unless $entry_ctx->{spec};
        if ($spec_match->{alias}) {
          $entry_ctx->{spec} = {
            'alias' => $ctx->{spec}{alias},
          };
        }
      }
    }
  }

  return $result;
});


# === prepareAuth ===

{
  my $setup_opts = get_spec($PRIMARY, 'prepareAuth', 'DEF', 'setup', 'a');
  my $auth_client = UnivecSDK->test(undef, $setup_opts);
  my $auth_utility = $auth_client->get_utility;

  runset('prepareAuth.basic', get_spec($PRIMARY, 'prepareAuth', 'basic'), sub {
    my ($entry) = @_;
    my $ctxmap = $entry->{ctx} || {};
    my $ctx = make_ctx_from_map($ctxmap, $auth_client, $auth_utility);
    fixctx($ctx, $auth_client);

    my (undef, $err) = $utility->{prepare_auth}->($ctx);
    die $err if $err;

    # Update entry ctx for match
    my $entry_ctx = $entry->{ctx};
    if (Voxgig::Struct::ismap($entry_ctx) && $ctx->{spec}) {
      $entry_ctx->{spec} = {
        'headers' => $ctx->{spec}{headers},
      };
    }

    return undef;
  });
}


# === prepareBody ===

runset('prepareBody.basic', get_spec($PRIMARY, 'prepareBody', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  fixctx($ctx, $client);
  return $utility->{prepare_body}->($ctx);
});


# === prepareHeaders ===

runset('prepareHeaders.basic', get_spec($PRIMARY, 'prepareHeaders', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  return $utility->{prepare_headers}->($ctx);
});


# === prepareMethod ===

runset('prepareMethod.basic', get_spec($PRIMARY, 'prepareMethod', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  return $utility->{prepare_method}->($ctx);
});


# === prepareParams ===

runset('prepareParams.basic', get_spec($PRIMARY, 'prepareParams', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  return $utility->{prepare_params}->($ctx);
});


# === preparePath ===

# Was two hand-written cases that had drifted out of the shared corpus
# (the preparePath fixture shipped as an empty `set: []`).
runset('preparePath.basic', get_spec($PRIMARY, 'preparePath', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  return $utility->{prepare_path}->($ctx);
});


# === prepareQuery ===

runset('prepareQuery.basic', get_spec($PRIMARY, 'prepareQuery', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  return $utility->{prepare_query}->($ctx);
});


# === resultBasic ===

runset('resultBasic.basic', get_spec($PRIMARY, 'resultBasic', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);
  fixctx($ctx, $client);

  my $result = $utility->{result_basic}->($ctx);

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

runset('resultBody.basic', get_spec($PRIMARY, 'resultBody', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);

  $utility->{result_body}->($ctx);

  my $entry_ctx = $entry->{ctx};
  if (Voxgig::Struct::ismap($entry_ctx) && $ctx->{result}) {
    $entry_ctx->{result} = {
      'body' => $ctx->{result}{body},
    };
  }

  return undef;
});


# === resultHeaders ===

runset('resultHeaders.basic', get_spec($PRIMARY, 'resultHeaders', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);

  $utility->{result_headers}->($ctx);

  my $entry_ctx = $entry->{ctx};
  if (Voxgig::Struct::ismap($entry_ctx) && $ctx->{result}) {
    $entry_ctx->{result} = {
      'headers' => $ctx->{result}{headers},
    };
  }

  return undef;
});


# === transformRequest ===

runset('transformRequest.basic', get_spec($PRIMARY, 'transformRequest', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);

  my $result = $utility->{transform_request}->($ctx);

  # Update entry ctx for match (step changed)
  my $entry_ctx = $entry->{ctx};
  if (Voxgig::Struct::ismap($entry_ctx) && $ctx->{spec}) {
    my $spec_map = $entry_ctx->{spec};
    $spec_map->{step} = $ctx->{spec}{step} if Voxgig::Struct::ismap($spec_map);
  }

  return $result;
});


# === transformResponse ===

runset('transformResponse.basic', get_spec($PRIMARY, 'transformResponse', 'basic'), sub {
  my ($entry) = @_;
  my $ctxmap = $entry->{ctx} || {};
  my $ctx = make_ctx_from_map($ctxmap, $client, $utility);

  my $result = $utility->{transform_response}->($ctx);

  # Update entry ctx for match (step changed)
  my $entry_ctx = $entry->{ctx};
  if (Voxgig::Struct::ismap($entry_ctx) && $ctx->{spec}) {
    my $spec_map = $entry_ctx->{spec};
    $spec_map->{step} = $ctx->{spec}{step} if Voxgig::Struct::ismap($spec_map);
  }

  return $result;
});

done_testing();
