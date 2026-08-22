#!perl
# Univec SDK entity stream() test
#
# Exercises the generated entity-base stream(action, args, callopts) method.
# stream() runs an operation through the full pipeline and returns an
# ITERATOR coderef (call it repeatedly; undef when exhausted). With the
# streaming feature active the result carries an incremental iterator and
# stream() yields from it (honouring chunkSize); otherwise it falls back to
# yielding the materialised items, so stream() always yields. API-agnostic:
# it discovers a top-level list entity from the config (a list op point with
# no required params) and seeds it via the test mock.

use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Scalar::Util ();

use UnivecSDK;

# True when this SDK was generated with the named feature.
sub has_feature {
  my ($name) = @_;
  my $f = UnivecConfig::make_config()->{feature};
  return (Voxgig::Struct::ismap($f) && defined $f->{$name}) ? 1 : 0;
}

# Discover an entity whose `list` op has a point with no required params, so
# the seeded list needs no path parameters. Returns (name, AccessorMethod).
sub find_list_entity {
  my $config = UnivecConfig::make_config();
  my $entities = UnivecHelpers::to_map(
    UnivecHelpers::gp($config, 'entity')) || {};
  for my $name (sort keys %$entities) {
    my $points = UnivecHelpers::gpath($config, "entity.$name.op.list.points");
    next unless Voxgig::Struct::islist($points);
    for my $p (@$points) {
      my $params = UnivecHelpers::gpath($p, 'args.params');
      my $reqd = Voxgig::Struct::islist($params)
        ? scalar(grep { UnivecHelpers::is_true($_->{reqd}) } @$params)
        : 0;
      return ($name, ucfirst($name)) if 0 == $reqd;
    }
  }
  return (undef, undef);
}

sub drain {
  my ($iter) = @_;
  my @seen;
  while (defined(my $item = $iter->())) {
    push @seen, $item;
  }
  return \@seen;
}

my ($entname, $method) = find_list_entity();

SKIP: {
  skip('no top-level list entity in this SDK', 1) unless defined $entname;

  # Seed three items for the discovered entity via the test mock. The mock's
  # init walk sets each record id to its map key.
  my $seed = {
    $entname => {
      'S1' => { 'id' => 'S1', 'name' => 'one' },
      'S2' => { 'id' => 'S2', 'name' => 'two' },
      'S3' => { 'id' => 'S3', 'name' => 'three' },
    },
  };

  # --- Fallback: no streaming feature -> materialised items. ---
  {
    my $sdk = UnivecSDK->test({ 'entity' => $seed }, undef);
    skip("SDK has no $method accessor", 1) unless $sdk->can($method);
    my $ent = $sdk->$method(undef);
    my $iter = $ent->stream('list', {}, undef);
    is(ref $iter, 'CODE', 'stream returns an iterator coderef');
    my $seen = drain($iter);
    is(scalar @$seen, 3, 'stream fallback yields all materialised items');
    ok((grep { Voxgig::Struct::ismap($_) && ($_->{id} // '') eq 'S2' } @$seen),
      'stream fallback yields bare record hashrefs');
  }

  # --- Streaming active: yields from the streaming feature's iterator. ---
  if (has_feature('streaming')) {
    {
      my $sdk = UnivecSDK->test(
        { 'entity' => $seed },
        { 'feature' => { 'streaming' => {
          'active' => Voxgig::Struct::JTRUE() } } });
      my $ent = $sdk->$method(undef);
      my $seen = drain($ent->stream('list', {}, undef));
      is(scalar @$seen, 3, 'stream (streaming active) yields all items');
      ok((grep { Voxgig::Struct::ismap($_) && ($_->{id} // '') eq 'S3' } @$seen),
        'stream (streaming active) yields bare records');
    }

    # chunkSize groups items into arrayref batches: 3 items / 2 -> [2, 1].
    {
      my $sdk = UnivecSDK->test(
        { 'entity' => $seed },
        { 'feature' => { 'streaming' => {
          'active' => Voxgig::Struct::JTRUE(), 'chunkSize' => 2 } } });
      my $ent = $sdk->$method(undef);
      my $batches = drain($ent->stream('list', {}, undef));
      is(scalar @$batches, 2, 'stream chunkSize groups items into 2 batches');
      is(scalar @{ $batches->[0] }, 2, 'stream chunkSize first batch size 2');
      is(scalar @{ $batches->[1] }, 1, 'stream chunkSize final batch size 1');
    }

    # signal cancels iteration between yields.
    {
      my $sdk = UnivecSDK->test(
        { 'entity' => $seed },
        { 'feature' => { 'streaming' => {
          'active' => Voxgig::Struct::JTRUE() } } });
      my $ent = $sdk->$method(undef);
      my $cancel = 0;
      my $iter = $ent->stream('list', {}, { 'signal' => sub { $cancel } });
      ok(defined $iter->(), 'stream signal: first item yielded before cancel');
      $cancel = 1;
      ok(!defined $iter->(), 'stream signal stops iteration when aborted');
    }
  }
  else {
    note('feature "streaming" not present; fallback path only');
  }
}

done_testing();
