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

# main.kit.test.live.strict is true (the default is true): a live
# request that fails, or a live test missing an input it needs,
# fails the test.
# An account with no record for a test to read skips it either way.
use constant LIVE_STRICT => 1;

{
  my $testsdk = UnivecSDK->test(undef, undef);
  my $ent = $testsdk->Model(undef);
  ok(defined $ent, 'model: create instance');
}

{
  package UnivecEntityTestModelFailHook;
  our @ISA = ('UnivecBaseFeature');

  sub new {
    my ($class) = @_;
    my $self = UnivecBaseFeature::new($class);
    $self->{name} = 'failhook';
    $self->{unexpected} = 0;
    return $self;
  }

  sub init { }
  sub PreSpec { die "model hook failed\n" }
  sub PreUnexpected { $_[0]->{unexpected}++; return }
}

{
  my $offline = { net => { offline => 1 } };
  my $died = !eval {
    my $next = UnivecSDK->test($offline, undef)->Model(undef)->stream('list', undef, undef);
    1 while defined $next->();
    1;
  };
  like($died ? "$@" : '', qr/offline/, 'model: a failed stream raises');

  ok(eval {
    my $next = UnivecSDK->test($offline, undef)->Model(undef)
      ->stream('list', undef, { ctrl => { throw => 0 } });
    1 while defined $next->();
    1;
  }, 'model: under throw false a failed stream ends');

  if (UnivecConfig::shared_config()->{feature}{rbac}) {
    my $denied = UnivecSDK->test(undef, { feature => { rbac => { active => 1, deny => 1 } } });
    my $denyerr = eval {
      my $next = $denied->Model(undef)->stream('list', undef, undef);
      1 while defined $next->();
      undef;
    } // $@;
    is(ref $denyerr ? $denyerr->{code} : undef, 'rbac_denied',
      'model: a denied stream raises');
  }
}

{
  my $explain = {};
  my $ctrl = { explain => $explain };
  my $next = UnivecSDK->test(undef, undef)->Model(undef)
    ->stream('list', undef, { ctrl => $ctrl });
  1 while defined $next->();
  is_deeply([sort keys %$ctrl], ['explain'], 'model: the stream leaves the caller ctrl');
  ok($explain == $ctrl->{explain} && 0 < keys %$explain,
    'model: the caller explain record is filled');
}

{
  my $hook = UnivecEntityTestModelFailHook->new;
  my $client = UnivecSDK->new({ feature => { test => { active => 1 } }, extend => [$hook] });

  my $err = eval { $client->Model(undef)->list(undef, undef); undef } // $@;
  like("$err", qr/hook failed/, 'model: a dying hook fails the operation');
  ok(0 < $hook->{unexpected}, 'model: PreUnexpected fired');

  my $fired = $hook->{unexpected};
  my $out = eval { $client->Model(undef)->list(undef, { throw => 0 }) };
  ok(!$@ && !defined $out, 'model: under throw false the call returns undef');
  ok($fired < $hook->{unexpected}, 'model: PreUnexpected fired under throw false');
}

{
  my $seed = { entity => { 'model' => { l1 => { id => 'l1' }, l2 => { id => 'l2' } } } };
  my $items = UnivecSDK->test($seed, undef)->Model(undef)->list(undef, undef);
  # list resolves to one entity per record; data_get reads the record.
  is(scalar(@$items), 2, 'model: list answers each seeded record');
  my $entities = grep {
    Scalar::Util::blessed($_) && $_->can('data_get') && Voxgig::Struct::ismap($_->data_get)
  } @$items;
  is($entities, 2, 'model: each listed item is an entity carrying its record');
}

SKIP: {
  skip('feature not present in this SDK: validate', 1)
    unless UnivecConfig::shared_config()->{feature}{validate};
  my $client = UnivecSDK->test(undef, { feature => { validate => { active => 1 } } });
  my $err = eval { $client->Model(undef)->list({ 'executionProvider' => 1 }, undef); undef } // $@;
  is(ref $err ? $err->{code} : undef, 'validate_failed',
    'model: an invalid request fails with validate_failed');
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

  # Whether *_ENTID supplied the idmap, read before env_override consumes
  # it: without it, the ids a live flow binds are the fixture's synthetic ones.
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
