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

  my $result = $client->direct({
    'path' => 'v1/models',
    'method' => 'GET',
    'params' => {},
  });
  if ($setup->{live}) {
    # Live mode is lenient: synthetic IDs frequently 4xx and the list-
    # response shape varies wildly across public APIs. Skip rather than
    # fail when the call doesn't return a usable list.
    if (defined $result->{err}) {
      note("list call failed (likely synthetic IDs against live API): $result->{err}");
      pass('direct-list-model: skipped (live)');
      last DIRECT_LIST;
    }
    unless ($result->{ok}) {
      note('list call not ok (likely synthetic IDs against live API)');
      pass('direct-list-model: skipped (live)');
      last DIRECT_LIST;
    }
    my $status = UnivecHelpers::to_int($result->{status});
    if ($status < 200 || $status >= 300) {
      note("expected 2xx status, got $status");
      pass('direct-list-model: skipped (live)');
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
    return {
      'client' => $client,
      'calls' => $calls,
      'live' => 1,
      'idmap' => {},
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
