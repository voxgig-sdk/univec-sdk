#!perl
# Model direct test

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd ();

use UnivecSDK;
require(Cwd::abs_path("$FindBin::Bin/runner.pm"));

# main.kit.test.live.strict is true (the default is true): a live
# request that fails, or a live test missing an input it needs,
# fails the test.
# An account with no record for a test to read skips it either way.
use constant LIVE_STRICT => 1;

sub live_ok {
  my ($result) = @_;
  my $status = UnivecHelpers::to_int($result->{status});
  return !defined $result->{err} && $result->{ok} && $status >= 200 && $status < 300;
}

DIRECT_LIST: {
  my $setup = model_direct_setup([
    { 'id' => 'direct01' },
    { 'id' => 'direct02' },
  ]);
  my ($_should_skip, $_reason) = UnivecTestRunner::is_control_skipped(
    'direct', 'direct-list-model', $setup->{live} ? 'live' : 'unit');
  if ($_should_skip) {
    note($_reason || 'skipped via sdk-test-control.json');
    pass('direct-list-model: skipped via sdk-test-control.json');
    last DIRECT_LIST;
  }
  my $client = $setup->{client};

  my $params = {};

  my $result = $client->direct({
    'path' => 'v1/models',
    'method' => 'GET',
    'params' => $params,
  });
  if ($setup->{live}) {
    if (!live_ok($result)) {
      UnivecTestRunner::live_miss(LIVE_STRICT, 'direct-list-model', 'Live list failed: ' . UnivecTestRunner::live_describe($result));
      last DIRECT_LIST;
    }
    if (!defined UnivecTestRunner::live_list($result->{data})) {
      UnivecTestRunner::live_miss(LIVE_STRICT, 'direct-list-model', 'Live list returned no list: ' . UnivecTestRunner::live_describe($result));
      last DIRECT_LIST;
    }
    pass('direct-list-model: live ok');
  }
  else {
    ok(!defined $result->{err}, 'direct-list-model: no error');
    ok($result->{ok}, 'direct-list-model: ok');
    is(UnivecHelpers::to_int($result->{status}), 200, 'direct-list-model: status');
    ok(Voxgig::Struct::islist($result->{data}), 'direct-list-model: data is array');
    is(scalar @{ $result->{data} }, 2, 'direct-list-model: data length');
    is(scalar @{ $setup->{calls} }, 1, 'direct-list-model: 1 call');
  }
}


sub model_direct_setup {
  my ($mockres) = @_;
  UnivecTestRunner::load_env_local();

  my $calls = [];

  my $env = UnivecTestRunner::env_override({
    'UNIVEC_TEST_MODEL_ENTID' => {},
    'UNIVEC_TEST_LIVE' => 'FALSE',
    'UNIVEC_APIKEY' => '',
  });

  my $live = ((($env->{'UNIVEC_TEST_LIVE'}) || '') eq 'TRUE') ? 1 : 0;

  if ($live) {
    # live_client_options() FIRST so the generated fields below win:
    # sdk-test-control.json's test.client.options adds to the live client,
    # it does not redirect it (a later key wins in a Perl hash literal).
    my $client = UnivecSDK->new({
      %{ UnivecTestRunner::live_client_options() },
      'apikey' => $env->{'UNIVEC_APIKEY'},
    });
    my $idmap = $env->{'UNIVEC_TEST_MODEL_ENTID'};
    return {
      'client' => $client,
      'calls' => $calls,
      'live' => 1,
      'idmap' => ref $idmap eq 'HASH' ? $idmap : {},
    };
  }

  my $mock_fetch = sub {
    my ($url, $init) = @_;
    push @$calls, { 'url' => $url, 'init' => $init };
    return ({
      'status' => 200,
      'statusText' => 'OK',
      'headers' => {},
      'json' => sub {
        return defined $mockres ? $mockres : { 'id' => 'direct01' };
      },
      'body' => 'mock',
    }, undef);
  };

  my $client = UnivecSDK->new({
    'base' => 'http://localhost:8080',
    'system' => {
      'fetch' => $mock_fetch,
    },
  });

  return {
    'client' => $client,
    'calls' => $calls,
    'live' => 0,
    'idmap' => {},
  };
}

done_testing();
