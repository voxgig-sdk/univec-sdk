#!perl
# Model entity test

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Cwd ();

use UnivecSDK;
require(Cwd::abs_path("$FindBin::Bin/runner.pm"));

{
  my $testsdk = UnivecSDK->test(undef, undef);
  my $ent = $testsdk->Model(undef);
  ok(defined $ent, 'model: create instance');
}

BASIC_FLOW: {
  my $setup = model_basic_setup(undef);
  my $_live = $setup->{live} ? 1 : 0;
  # Per-op sdk-test-control.json skip.
  for my $_op (('list')) {
    my ($_should_skip, $_reason) = UnivecTestRunner::is_control_skipped(
      'entityOp', "model." . $_op, $_live ? 'live' : 'unit');
    if ($_should_skip) {
      note($_reason || 'skipped via sdk-test-control.json');
      pass('model: basic flow skipped via sdk-test-control.json');
      last BASIC_FLOW;
    }
  }
  # The basic flow consumes synthetic IDs from the fixture. In live mode
  # without an *_ENTID env override, those IDs hit the live API and 4xx.
  if ($setup->{synthetic_only}) {
    note('live entity test uses synthetic IDs from fixture - set UNIVEC_TEST_MODEL_ENTID JSON to run live');
    pass('model: basic flow skipped (synthetic IDs only)');
    last BASIC_FLOW;
  }
  my $client = $setup->{client};
  my %V;

  # Bootstrap entity data from existing test data.
  $V{model_ref01_data_raw} = Voxgig::Struct::items(UnivecHelpers::to_map(
    UnivecHelpers::gpath($setup->{data}, 'existing.model')));
  $V{model_ref01_data} = undef;
  if (@{ $V{model_ref01_data_raw} || [] }) {
    $V{model_ref01_data} = UnivecHelpers::to_map($V{model_ref01_data_raw}[0][1]);
  }

  # LIST
  $V{model_ref01_ent} = $client->Model(undef);
  $V{model_ref01_match} = {};

  $V{model_ref01_list_result} = $V{model_ref01_ent}->list($V{model_ref01_match}, undef);
  ok(Voxgig::Struct::islist($V{model_ref01_list_result}), 'model list: is array');

}

sub model_basic_setup {
  my ($extra) = @_;
  UnivecTestRunner::load_env_local();

  my $entity_data_file = Cwd::abs_path(
    "$FindBin::Bin/../../.sdk/test/entity/model/ModelTestData.json");
  my $entity_data = do {
    open my $fh, '<:raw', $entity_data_file or die "Cannot open $entity_data_file: $!";
    local $/;
    Voxgig::Struct::parse_json(<$fh>);
  };

  my $options = {};
  $options->{entity} = $entity_data->{existing};

  my $client = UnivecSDK->test($options, $extra);

  # Generate idmap via transform.
  my $idmap = Voxgig::Struct::transform(
    ['model01', 'model02', 'model03'],
    {
      '`$PACK`' => ['', {
        '`$KEY`' => '`$COPY`',
        '`$VAL`' => ['`$FORMAT`', 'upper', '`$COPY`'],
      }],
    }
  );

  # Detect ENTID env override before env_override consumes it. When live
  # mode is on without a real override, the basic test runs against
  # synthetic IDs from the fixture and 4xx's. Surface this so the test can
  # skip.
  my $entid_env_raw = $ENV{'UNIVEC_TEST_MODEL_ENTID'};
  my $idmap_overridden = (defined $entid_env_raw && $entid_env_raw =~ /^\s*\{/) ? 1 : 0;

  my $env = UnivecTestRunner::env_override({
    'UNIVEC_TEST_MODEL_ENTID' => $idmap,
    'UNIVEC_TEST_LIVE' => 'FALSE',
    'UNIVEC_TEST_EXPLAIN' => 'FALSE',
    'UNIVEC_APIKEY' => '',
  });

  my $idmap_resolved = UnivecHelpers::to_map($env->{'UNIVEC_TEST_MODEL_ENTID'});
  if (!defined $idmap_resolved) {
    $idmap_resolved = UnivecHelpers::to_map($idmap);
  }

  if ((($env->{'UNIVEC_TEST_LIVE'}) || '') eq 'TRUE') {
    my $merged_opts = Voxgig::Struct::merge([
      # FIRST, so the generated fields below win: sdk-test-control.json's
      # test.client.options adds to the live client, it does not redirect it.
      UnivecTestRunner::live_client_options(),
      {
        'apikey' => $env->{'UNIVEC_APIKEY'},
      },
      (Voxgig::Struct::ismap($extra) ? $extra : {}),
    ]);
    $client = UnivecSDK->new(UnivecHelpers::to_map($merged_opts));
  }

  my $live = ((($env->{'UNIVEC_TEST_LIVE'}) || '') eq 'TRUE') ? 1 : 0;
  return {
    'client' => $client,
    'data' => $entity_data,
    'idmap' => $idmap_resolved,
    'env' => $env,
    'explain' => ((($env->{'UNIVEC_TEST_EXPLAIN'}) || '') eq 'TRUE') ? 1 : 0,
    'live' => $live,
    'synthetic_only' => ($live && !$idmap_overridden) ? 1 : 0,
    'now' => UnivecHelpers::now_ms(),
  };
}

done_testing();
