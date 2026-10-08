#!perl
# Embed entity test

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

{
  my $testsdk = UnivecSDK->test(undef, undef);
  my $ent = $testsdk->Embed(undef);
  ok(defined $ent, 'embed: create instance');
}

SKIP: {
  skip('feature not present in this SDK: validate', 1)
    unless UnivecConfig::shared_config()->{feature}{validate};
  my $client = UnivecSDK->test(undef, { feature => { validate => { active => 1 } } });
  my $err = eval { $client->Embed(undef)->create({ 'embeddings' => 'x', 'model' => 1, 'texts' => 'x' }, undef); undef } // $@;
  is(ref $err ? $err->{code} : undef, 'validate_failed',
    'embed: an invalid request fails with validate_failed');
}

BASIC_FLOW: {
  my $setup = embed_basic_setup(undef);
  my $_live = $setup->{live} ? 1 : 0;
  # Per-op sdk-test-control.json skip.
  for my $_op (('create')) {
    my ($_should_skip, $_reason) = UnivecTestRunner::is_control_skipped(
      'entityOp', "embed." . $_op, $_live ? 'live' : 'unit');
    if ($_should_skip) {
      note($_reason || 'skipped via sdk-test-control.json');
      pass('embed: basic flow skipped via sdk-test-control.json');
      last BASIC_FLOW;
    }
  }
  my $client = $setup->{client};
  my %V;

  # CREATE
  $V{embed_ref01_ent} = $client->Embed(undef);
  $V{embed_ref01_data} = UnivecHelpers::to_map(UnivecHelpers::gp(
    UnivecHelpers::gpath($setup->{data}, 'new.embed'), 'embed_ref01'));

  $V{embed_ref01_data_result} = $V{embed_ref01_ent}->create($V{embed_ref01_data}, undef);
  $V{embed_ref01_data} = UnivecHelpers::to_map(ref($V{embed_ref01_data_result}) && $V{embed_ref01_data_result}->can('data_get') ? $V{embed_ref01_data_result}->data_get : $V{embed_ref01_data_result});
  ok(defined $V{embed_ref01_data}, 'embed create: data');

}

sub embed_basic_setup {
  my ($extra) = @_;
  UnivecTestRunner::load_env_local();

  my $entity_data_file = Cwd::abs_path(
    "$FindBin::Bin/../../.sdk/test/entity/embed/EmbedTestData.json");
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
    ['embed01', 'embed02', 'embed03'],
    {
      '`$PACK`' => ['', {
        '`$KEY`' => '`$COPY`',
        '`$VAL`' => ['`$FORMAT`', 'upper', '`$COPY`'],
      }],
    }
  );

  # Whether *_ENTID supplied the idmap, read before env_override consumes
  # it: without it, the ids a live flow binds are the fixture's synthetic ones.
  my $entid_env_raw = $ENV{'UNIVEC_TEST_EMBED_ENTID'};
  my $idmap_overridden = (defined $entid_env_raw && $entid_env_raw =~ /^\s*\{/) ? 1 : 0;

  my $env = UnivecTestRunner::env_override({
    'UNIVEC_TEST_EMBED_ENTID' => $idmap,
    'UNIVEC_TEST_LIVE' => 'FALSE',
    'UNIVEC_TEST_EXPLAIN' => 'FALSE',
    'UNIVEC_APIKEY' => '',
  });

  my $idmap_resolved = UnivecHelpers::to_map($env->{'UNIVEC_TEST_EMBED_ENTID'});
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
