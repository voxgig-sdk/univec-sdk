# Univec SDK cost feature
#
# Cost tracking and spend budget. Uses BOTH seams, which is the point of the
# feature: money is spent per HTTP ATTEMPT (a retried call is charged again,
# because the upstream API charges it again), but it is owed by an
# OPERATION. So the transport wrap prices each attempt, and PreDone
# attributes the running total to "<entity>.<op>" and to the caller (the
# per-call ctrl actor, the same actor the audit feature records).
#
# The price of an attempt comes from the first source that answers: a
# response header ("header" x "perUnit"), the rate table ("rates", keyed
# "<entity>.<op>" / "<op>" / "*"), then the flat "unit". A body figure
# ("path" x "perUnit", e.g. "usage.total_tokens") is read at PreDone
# instead, from the already-parsed result, and describes the whole call, so
# it REPLACES the per-attempt estimate rather than adding to it.
#
# "budget" caps total spend. With "onBudget" => "deny" a further operation
# is refused at PrePoint, before an endpoint is resolved and before anything
# reaches the network.
#
# ORDER MATTERS. Cost must sit INSIDE the cache, or a response served from
# cache is charged for money that was never spent. The default (map) order
# puts cache innermost and cost outside it, so activate them in list form
# with cost first.

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecCostFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'cost';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  # Keyed by ctx refaddr, same as metrics' start markers.
  $self->{pending} = {};
  $self->{seq} = 0;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  $self->{pending} = {};
  $self->{seq} = 0;

  my $limit = $self->_limit;

  if (!$self->{client}{_cost}) {
    $self->{client}{_cost} = {
      'currency' => defined $self->{options}{currency} ? $self->{options}{currency} : 'USD',
      'total' => {
        'calls' => 0, 'attempts' => 0,
        'amount' => 0, 'reported' => 0, 'estimated' => 0,
      },
      'ops' => {},
      'actors' => {},
      'budget' => {
        'limit' => $limit, 'spent' => 0,
        'remaining' => $limit, 'exceeded' => 0,
      },
      'last' => undef,
    };
  }

  return unless $self->{active};

  my $feature = $self;
  my $utility = $ctx->{utility};
  my $inner = $utility->{fetcher};

  $utility->{fetcher} = sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    return $feature->charge($fctx, $fullurl, $fetchdef, $inner);
  };
  return;
}

# The budget gate. Runs before endpoint resolution, so a refused call costs
# nothing at all.
sub PrePoint {
  my ($self, $ctx) = @_;
  return unless $self->{active};

  # Mark the context as running through the pipeline, so charge knows a
  # PreDone is coming and does not commit the spend itself.
  my $addr = Scalar::Util::refaddr($ctx);
  my $entry = $self->{pending}{$addr};
  if (!$entry) {
    $entry = $self->_new_pending;
    $self->{pending}{$addr} = $entry;
  }
  $entry->{piped} = 1;

  my $limit = $self->_limit;
  return if $limit <= 0;

  my $cost = $self->{client}{_cost};
  return unless $cost;
  return if $cost->{total}{amount} < $limit;

  $cost->{budget}{exceeded} = 1;

  my $on = defined $self->{options}{onBudget} ? $self->{options}{onBudget} : 'warn';
  return unless 'deny' eq $on;

  my $err = $ctx->make_error('cost_budget',
    'Cost budget of ' . $self->_numstr($limit) . ' ' . $cost->{currency}
    . ' is spent (' . $self->_numstr($cost->{total}{amount}) . ' '
    . $cost->{currency} . ' used)');

  # Short-circuit endpoint resolution; the pipeline surfaces this error.
  $ctx->{out}{point} = $err;
  return;
}

sub charge {
  my ($self, $ctx, $url, $fetchdef, $inner) = @_;

  # A dying transport still costs an attempt. Without this, a run of
  # connection-level failures under "retry" (which traps and tries again)
  # would be charged nothing at all, and an onBudget "deny" ceiling could
  # never stop it.
  my ($res, $err);
  my $threw;
  {
    local $@;
    my $ok = eval {
      ($res, $err) = $inner->($ctx, $url, $fetchdef);
      1;
    };
    if (!$ok) {
      $threw = $@ || "cost: transport died";
      $res = undef;
      $err = $threw;
    }
  }

  my ($amount, $source) = $self->_price($ctx, $res);

  my $addr = Scalar::Util::refaddr($ctx);
  my $entry = $self->{pending}{$addr};
  if (!$entry) {
    $entry = $self->_new_pending;
    $self->{pending}{$addr} = $entry;
  }

  $entry->{attempts} += 1;

  # Accumulated here, committed once at PreDone. Adding each attempt to the
  # running total and then subtracting it again when a body figure
  # supersedes it loses precision to catastrophic cancellation.
  #
  # Reported and estimated are kept apart per ATTEMPT: a 503 priced from the
  # rate table followed by a 200 carrying the cost header is part estimate,
  # part reported, and collapsing both into the final attempt's category
  # would corrupt the split.
  $entry->{amount} += $amount;
  my $bucket = ('header' eq $source || 'body' eq $source) ? 'reported' : 'estimated';
  $entry->{$bucket} += $amount;
  $entry->{source} = $source;

  my $cost = $self->{client}{_cost};
  $cost->{total}{attempts} += 1 if $cost;

  # direct() and graphql() reach the transport without dispatching any
  # pipeline hooks, so there is no PrePoint to gate on and no PreDone to
  # commit. Their spend is committed here, or it would never be counted.
  # "piped" is set by PrePoint, so its absence is the signal.
  if (!$entry->{piped}) {
    $self->_commit($ctx, $entry, '_', 'direct');
    delete $self->{pending}{$addr};
  }

  die $threw if defined $threw;

  return ($res, $err);
}

sub _new_pending {
  my ($self) = @_;
  return {
    'attempts' => 0, 'amount' => 0,
    'reported' => 0, 'estimated' => 0,
    'source' => 'none', 'piped' => 0,
  };
}

# Attribute the operation's spend once the call is finished.
sub PreDone {
  my ($self, $ctx) = @_;
  $self->_finish($ctx, 1);
  return;
}

# A failed operation still spent the money. When the pipeline dies, PreDone
# never runs, so without this the attempts are counted and the spend is not,
# and a budget could never see the cost of a failed call. Whichever hook fires
# first consumes the pending entry, so it commits exactly once.
sub PreUnexpected {
  my ($self, $ctx) = @_;
  $self->_finish($ctx, 0);
  return;
}

sub _finish {
  my ($self, $ctx, $done) = @_;
  return unless $self->{active};
  my $addr = Scalar::Util::refaddr($ctx);
  return unless exists $self->{pending}{$addr};
  my $entry = delete $self->{pending}{$addr};

  # A FAILED operation that made no attempt never reached the network:
  # PrePoint creates the pending entry to mark the context as piped, and
  # then the budget gate refuses the call (rbac, or an unresolvable
  # endpoint, short-circuits just as early). Committing it would count a
  # call that never happened and file a zero-amount record as `last`.
  #
  # A SUCCEEDED operation that made no attempt is the opposite case: it was
  # served from the cache. That is a real call, and the fact that it cost
  # nothing is the whole point of ordering cost inside the cache.
  return if !$done && 0 == $entry->{attempts};

  my $entity = ($ctx->{op} && defined $ctx->{op}{entity} && '' ne $ctx->{op}{entity})
    ? $ctx->{op}{entity} : '_';
  my $opname = ($ctx->{op} && defined $ctx->{op}{name} && '' ne $ctx->{op}{name})
    ? $ctx->{op}{name} : '_';

  $self->_commit($ctx, $entry, $entity, $opname);
  return;
}

# Commit one operation's spend: totals, budget, per-op and per-actor
# attribution, and the record. Shared by _finish and the raw-request path in
# charge, which has no PreDone to reach.
sub _commit {
  my ($self, $ctx, $entry, $entity, $opname) = @_;

  my $cost = $self->{client}{_cost};
  return unless $cost;

  my $amount = $entry->{amount};
  my $reported = $entry->{reported};
  my $estimated = $entry->{estimated};
  my $source = $entry->{source};

  # A body figure prices the whole call, so it replaces the per-attempt
  # estimate rather than adding to it, and being server-stated the whole
  # amount counts as reported.
  my $body = $self->_body($ctx);
  if (defined $body) {
    $amount = $body;
    $reported = $body;
    $estimated = 0;
    $source = 'body';
  }

  $self->_spend($cost, $amount, $reported, $estimated);

  my $actor = $self->_actor($ctx);

  $cost->{total}{calls} += 1;
  $self->_bump($cost->{ops}, "$entity.$opname", $amount);
  $self->_bump($cost->{actors}, $actor, $amount);

  $self->{seq} += 1;
  my $record = {
    'seq' => $self->{seq},
    'entity' => $entity,
    'op' => $opname,
    'actor' => $actor,
    'amount' => $amount,
    'currency' => $cost->{currency},
    'source' => $source,
    'attempts' => $entry->{attempts},
  };
  $cost->{last} = $record;

  my $sink = $self->{options}{sink};
  if (ref $sink eq 'CODE') {
    # A failing sink must never take down the call.
    eval { $sink->($record) };
  }
  return;
}

# Price one attempt: a reported header figure, else the rate table, else the
# flat unit.
sub _price {
  my ($self, $ctx, $res) = @_;

  my $header = $self->{options}{header};
  if (defined $header && '' ne $header) {
    my $val = $self->_header($res, $header);
    return ($val * $self->_per_unit, 'header') if defined $val;
  }

  my $rate = $self->_rate($ctx);
  return ($rate, 'table') if defined $rate;

  my $unit = $self->{options}{unit};
  return ($unit, 'unit')
    if defined $unit && !ref($unit) && Scalar::Util::looks_like_number($unit) && 0 != $unit;

  return (0, 'none');
}

# The rate table uses the same lookup grammar as rbac's rules:
# "<entity>.<op>", then "<op>", then "*".
sub _rate {
  my ($self, $ctx) = @_;
  my $rates = $self->{options}{rates};
  return undef unless Voxgig::Struct::ismap($rates);

  my $entity = '';
  if ($ctx->{entity} && defined $ctx->{entity}{name}) {
    $entity = $ctx->{entity}{name};
  }
  elsif ($ctx->{op} && defined $ctx->{op}{entity}) {
    $entity = $ctx->{op}{entity};
  }
  my $opname = ($ctx->{op} && defined $ctx->{op}{name}) ? $ctx->{op}{name} : '';

  for my $key ("$entity.$opname", $opname, '*') {
    my $val = $rates->{$key};
    return $val
      if defined $val && !ref($val) && Scalar::Util::looks_like_number($val);
  }
  return undef;
}

# A usage figure from the parsed result body, priced by perUnit. Read here,
# not at the transport seam, because the body is one-shot.
sub _body {
  my ($self, $ctx) = @_;
  my $path = $self->{options}{path};
  return undef unless defined $path && '' ne $path;
  return undef unless $ctx->{result} && defined $ctx->{result}{body};

  my $val = Voxgig::Struct::getpath($ctx->{result}{body}, $path);
  my $num = $self->_num($val);
  return undef unless defined $num;
  return $num * $self->_per_unit;
}

sub _spend {
  my ($self, $cost, $amount, $reported, $estimated) = @_;
  $cost->{total}{amount} += $amount;
  $cost->{total}{reported} += $reported;
  $cost->{total}{estimated} += $estimated;

  my $limit = $cost->{budget}{limit};
  $cost->{budget}{spent} = $cost->{total}{amount};
  if ($limit > 0) {
    my $rem = $limit - $cost->{total}{amount};
    $cost->{budget}{remaining} = $rem > 0 ? $rem : 0;
    $cost->{budget}{exceeded} = 1 if $cost->{total}{amount} >= $limit;
  }
  else {
    $cost->{budget}{remaining} = 0;
  }
  return;
}

sub _bump {
  my ($self, $bucket, $key, $amount) = @_;
  my $entry = $bucket->{$key};
  if (!$entry) {
    $entry = { 'calls' => 0, 'amount' => 0 };
    $bucket->{$key} = $entry;
  }
  $entry->{calls} += 1;
  $entry->{amount} += $amount;
  return;
}

sub _header {
  my ($self, $res, $name) = @_;
  return undef unless Voxgig::Struct::ismap($res);
  my $headers = $res->{headers};
  return undef unless Voxgig::Struct::ismap($headers);
  my $lower = lc($name);
  for my $key (keys %$headers) {
    return $self->_num($headers->{$key}) if lc("$key") eq $lower;
  }
  return undef;
}

sub _num {
  my ($self, $val) = @_;
  return undef unless defined $val;
  return undef if ref $val;
  return 0 + $val if Scalar::Util::looks_like_number($val);
  return undef;
}

sub _actor {
  my ($self, $ctx) = @_;
  if ($ctx->{ctrl} && defined $ctx->{ctrl}{actor}) {
    return $ctx->{ctrl}{actor};
  }
  return defined $self->{options}{actor} ? $self->{options}{actor} : 'anonymous';
}

sub _per_unit {
  my ($self) = @_;
  my $per = $self->{options}{perUnit};
  return (defined $per && !ref($per) && Scalar::Util::looks_like_number($per)) ? $per : 0;
}

sub _limit {
  my ($self) = @_;
  my $budget = $self->{options}{budget};
  return (defined $budget && !ref($budget) && Scalar::Util::looks_like_number($budget))
    ? $budget : 0;
}

# Render a money amount without an exponent or trailing zeros.
sub _numstr {
  my ($self, $n) = @_;
  my $s = sprintf('%.10f', $n);
  $s =~ s/0+$//;
  $s =~ s/\.$//;
  return '' eq $s ? '0' : $s;
}

1;
