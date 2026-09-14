# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Host.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Host;

# The host: the lifecycle state machine (section 5), extension points
# (section 6), and resource capture (section 8).
#
# TWO RULES SHAPE EVERY METHOD BELOW.
#
# Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
# never interleaved; a transition triggered from inside a lifecycle
# callback is `plugin_reentrant`. A hard rule, because it is the only way
# the semantics can be identical in Go, in Perl and in single-threaded
# JavaScript.
#
# Reconciliation is EAGER (section 18's portability budget). A transition
# settles by running the state machine to a fixed point, not by suspending
# on a promise.
#
# A PERL HASH HAS NO ORDER, and a deliberately randomized one at that.
# Every walk of the registry here sorts its keys first: `sort keys %$inst`
# is not tidiness, it is the difference between a deterministic teardown
# and one that changes between runs of the same process.

use strict;
use warnings;
use sort 'stable';
use Voxgig::Plugin::Types qw(fail_with codeof jsontype ismap islist truthy
                             sortstrings sortedkeys stable_sort_by);
use Voxgig::Plugin::Ref qw(canon canon_ref format_ref parse_ref refname);
use Voxgig::Plugin::Catalog qw(make_catalog);
use Voxgig::Plugin::Order qw(resolve_order);
use Voxgig::Plugin::Point qw(point_emit compose point_provider);
use Voxgig::Plugin::Export qw(resolve_export);
use Voxgig::Plugin::Capability qw(resolve_capability);
use Voxgig::Plugin::Config qw(normalize_config resolve_options);
use Voxgig::Plugin::Depend qw(requirements restartsonloss gatesactivation checkcycle);

use Exporter 'import';
our @EXPORT_OK = qw(make_host);

# ---------------------------------------------------------------------
# Inst - what a definition's callbacks see
# ---------------------------------------------------------------------
#
# Deliberately not the internal record: a plugin that could reach `status`
# could also write it.

{
    package Voxgig::Plugin::Inst;

    use strict;
    use warnings;
    use Voxgig::Plugin::Types qw(fail_with);
    use Voxgig::Plugin::Ref qw(parse_ref);

    sub new {
        my ($class, $host, $entry) = @_;
        my $parsed = parse_ref($entry->{ref});
        return bless {
            host  => $host,
            entry => $entry,
            ref   => $entry->{ref},
            name  => $parsed->{name},
            tag   => $parsed->{tag},
        }, $class;
    }

    sub ref  { $_[0]->{ref} }
    sub name { $_[0]->{name} }
    sub tag  { $_[0]->{tag} }
    sub host { $_[0]->{host} }

    # The resolved options and the instance's own state, both live: a
    # hashref is a reference, so a callback that keeps one sees what
    # `apply` and `options` write into it.
    sub options { $_[0]->{entry}{options} }
    sub state   { $_[0]->{entry}{state} }

    # Foreign resources the host did not hand out are registered explicitly
    # (section 8.3); host calls are recorded automatically.
    #
    # SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
    # resources CURRENTLY HELD, so an entry that is registered and then
    # unwound must leave the count where it found it.
    sub release {
        my ($self, $fn) = @_;
        # Section 8.3: "`inst.release` outside `activate` is
        # `plugin_release_scope`". A flag saying merely that a transition
        # is running is true in `define` too, and a scope entry registered
        # there is never unwound.
        fail_with('plugin_release_scope', 'release called outside activate')
            if 'activate' ne ($self->{host}->phase // '');
        my $host = $self->{host};
        my $done = 0;
        push @{ $self->{entry}{scope} }, sub {
            return if $done;
            $done = 1;
            $host->open_dec;
            $fn->();
        };
        $host->open_inc;
        return;
    }

    # The synthetic counter the driver owns, so "what is open" is data
    # rather than an assertion each port words differently.
    #
    # Returns its own release, so a plugin can hand one back early. The
    # scope still holds the entry and unwinding it twice is a no-op -
    # releasing early must not make teardown wrong.
    sub acquire {
        my ($self) = @_;
        # Section 8.1: resources are "acquired during `activate` - the
        # scope's actual job". Same reason as `release` above.
        fail_with('plugin_release_scope', 'acquire called outside activate')
            if 'activate' ne ($self->{host}->phase // '');
        my $host = $self->{host};
        my $done = 0;
        my $rel = sub {
            return if $done;
            $done = 1;
            $host->open_dec;
        };
        push @{ $self->{entry}{scope} }, $rel;
        $host->open_inc;
        return $rel;
    }

    # Bind into a host point. Declared in `define`; the host inserts it
    # only after `activate` returns successfully (section 8.1), which is
    # why a failing activate leaves no live binding behind.
    sub bind {
        my ($self, $point, $fn, $band) = @_;
        # Section 12 has carried `plugin_bind_scope` - "binding declared
        # outside `define`" - since before anything raised it. Section 8.1
        # puts binding DECLARATION in `define` and INSERTION at a
        # successful activate, and the guard was the half nobody wrote: a
        # binding added from `activate` went live without being part of the
        # loaded definition, and a deactivate/activate cycle appended it
        # again.
        fail_with('plugin_bind_scope', "bind called outside define: $point",
                  { ref => $self->{ref}, point => $point })
            if 'define' ne ($self->{host}->phase // '');
        fail_with('plugin_point_unknown', "no such point: $point",
                  { point => $point })
            if !$self->{host}->haspoint($point);
        push @{ $self->{entry}{bindings} },
            { ref => $self->{ref}, point => $point, fn => $fn,
              band => $band // 0 };
        return;
    }

    # Published for other plugins and for the application (section 11).
    sub export {
        my ($self, $key, $value) = @_;
        $self->{entry}{exports}{$key} = $value;
        return;
    }

    # What this instance can do for others (section 11.1).
    sub provides {
        my ($self, $prov) = @_;
        push @{ $self->{entry}{provides} }, $prov;
        return;
    }

    # Where this binding landed (section 6.6) - the plugin-side counterpart
    # to a host pin. THE HOST DOES NOT POLICE THIS; it just makes the fact
    # available. Verification tells a plugin it was misplaced; a pin
    # (section 7) stops the misplacement from being expressible at all. The
    # two are not substitutes.
    sub position {
        my ($self, $point) = @_;
        return $self->{host}->positionof($self->{ref}, $point);
    }

    # AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER ONE
    # OWNS THE INNER ONE'S LIFETIME. Registering the teardown in the
    # instance scope is what makes that true rather than aspirational.
    sub nest {
        my ($self, $nestopts) = @_;
        fail_with('plugin_release_scope', 'nest called outside a lifecycle callback')
            if !$self->{host}->intransition;
        my $inner = Voxgig::Plugin::Host->new($nestopts);
        push @{ $self->{entry}{scope} }, sub { $inner->close };
        $self->{entry}{inner} = $inner;
        return $inner;
    }
}

# ---------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------

sub new {
    my ($class, $options) = @_;
    my $opts = $options // {};
    my $self = bless {
        opts       => $opts,
        dependency => $opts->{dependency} // 'restart',
        # Set for the duration of a bulk teardown, so `held` knows this is
        # a coordinated operation rather than an ad-hoc deactivation.
        coordinated => 0,
        catalog    => $opts->{catalog} // make_catalog(),
        reserved   => $opts->{reserved} // [],
        points     => $opts->{points} // {},
        inst       => {},
        log        => [],
        # Section 14: the lifecycle event record. `seq` distinguishes ONE
        # INCARNATION of stripe$test from the next, which is the whole
        # reason it is not `pos` (section 4 rule 4).
        events     => [],
        seqn       => 0,
        open       => 0,
        transition => 0,
        # WHICH callback is running, not merely that one is. Section 8.1
        # puts resource capture in `activate` and 8.3 says `release`
        # outside `activate` is `plugin_release_scope` - and a bare flag
        # cannot tell `activate` from `define`, so it admitted an acquire
        # in `define` whose scope `unload` would never unwind.
        phase      => undef,
    }, $class;
    return $self;
}

sub catalog       { $_[0]->{catalog} }
sub intransition  { $_[0]->{transition} }
sub phase         { $_[0]->{phase} }
sub haspoint      { exists $_[0]->{points}{ $_[1] } ? 1 : 0 }
sub open_inc      { $_[0]->{open}++; return }
sub open_dec      { $_[0]->{open}--; return }

# --- observation ------------------------------------------------------

# Introspection NEVER advances the state (section 5.2). A status page must
# not be a way to accidentally import twenty packages.
sub list {
    my ($self) = @_;
    my %out;
    $out{$_} = $self->{inst}{$_}{status} for keys %{ $self->{inst} };
    return \%out;
}

sub instance {
    my ($self, $ref) = @_;
    return $self->{inst}{ canon_ref($ref) };
}

sub trace {
    my ($self) = @_;
    return [ @{ $self->{events} } ];
}

sub observable {
    my ($self, $result) = @_;
    return { status => $self->list, open => $self->{open},
             log => [ @{ $self->{log} } ], result => $result };
}

# --- the state machine ------------------------------------------------

sub guard {
    my ($self) = @_;
    return if !$self->{transition};
    fail_with('plugin_reentrant',
              'transition attempted from inside a lifecycle callback');
}

sub need {
    my ($self, $ref) = @_;
    my $r = canon_ref($ref);
    my $entry = $self->{inst}{$r};
    fail_with('plugin_not_loaded', "no such instance: $r", { ref => $r })
        if !defined $entry;
    return $entry;
}

sub checkreserved {
    my ($self, $ref) = @_;
    return if !@{ $self->{reserved} };
    my $name = refname($ref);
    return if !grep { $_ eq $name } @{ $self->{reserved} };
    fail_with('plugin_ref_reserved', "ref is reserved by the host: $ref",
              { ref => $ref });
}

sub run {
    my ($self, $entry, $callback, $at) = @_;
    my $fn = $entry->{def}{$callback};
    push @{ $self->{log} }, "$entry->{ref}:$at";
    push @{ $self->{events} },
        { ref => $entry->{ref}, event => $at, seq => $entry->{seq},
          status => $entry->{status} };
    return if 'CODE' ne (ref($fn) // '');

    $self->{transition} = 1;
    $self->{phase} = $at;
    my $ok = eval { $fn->(Voxgig::Plugin::Inst->new($self, $entry)); 1 };
    my $err = $@;
    $self->{transition} = 0;
    $self->{phase} = undef;
    return if $ok;

    # Section 12: `plugin_define_failed` and its three siblings are "a
    # callback raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A
    # CODE KEEPS IT - the code is the error's identity, and a plugin
    # raising `store_unreachable` must not have it rewritten. Only a
    # code-less error is wrapped.
    die $err if '' ne codeof($err);

    my $cause = "$err";
    $cause =~ s/\s+\z//;
    fail_with("plugin_${at}_failed", "$entry->{ref} raised in $at: $cause",
              { ref => $entry->{ref}, cause => $cause });
}

# AUTO-TAGGING IS EXPLICIT (section 4 rule 3). `declare('stripe', {tag =>
# '?'})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the
# assigned pair. Without `'?'`, a collision is an error.
sub autotag {
    my ($self, $name) = @_;
    my $n = 1;
    while (1) {
        my $cand = format_ref($name, "$n");
        return $cand if !exists $self->{inst}{$cand};
        $n++;
    }
}

sub declare {
    my ($self, $ref, $spec) = @_;
    $spec //= {};
    $ref = $self->autotag(refname(canon_ref($ref)))
        if defined $spec->{tag} && '?' eq $spec->{tag};
    my $r = canon_ref($ref);
    $self->checkreserved($r) if !truthy($spec->{hostowned});
    my $defname = $spec->{definition} // refname($r);
    my $definition = $self->{catalog}->get($defname);
    fail_with('plugin_unknown_definition', "not in catalog: $defname",
              { name => $defname })
        if !defined $definition;

    my $existing = $self->{inst}{$r};
    if (defined $existing) {
        # Section 4 rule 1: a pair addresses at most one instance.
        # Re-declaring the SAME definition is the idempotent case; a
        # different one is a duplicate, not a silent overwrite (seneca) and
        # not an impossibility (sdkgen).
        fail_with('plugin_ref_duplicate', "instance already declared: $r",
                  { ref => $r })
            if $existing->{def}{name} ne $definition->{name};
        return $existing;
    }

    my $entry = {
        ref => $r, def => $definition, status => 'declared',
        pos => defined $spec->{pos} ? $spec->{pos} : scalar keys %{ $self->{inst} },
        seq => $self->{seqn},
        options => $spec->{options} // {},
        state => {}, order => $spec->{order}, unmet => [], scope => [],
        # Section 11.4's ALWAYS-RELUCTANT rebinding made concrete: the
        # provider ref this instance's activation actually chose, per
        # requirement name. Re-ranking on every question silently
        # re-points a live consumer at any better newcomer, and then
        # losing the provider it was really using does not restart it.
        selected => {},
        bindings => [], exports => {}, provides => [], inner => undef,
        barred => 0,
    };
    $self->{seqn}++;
    $self->{inst}{$r} = $entry;
    return $entry;
}

# Section 9.1: a host that reserves a name MUST still be able to declare
# the instance it reserved - "The host declares those instances itself,
# after the user merge, and always wins."
#
# THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit: no
# language here can tell the embedding host from a plugin holding the same
# host object. What reservation protects is CONFIGURATION - documents,
# overlays, `VOXGIG_PLUGIN_*`, construction options and ordinary
# declare/load/options - and all of that still checks.
sub hostdeclare {
    my ($self, $ref, $spec) = @_;
    $self->guard;
    return $self->declare($ref, { %{ $spec // {} }, hostowned => 1 });
}

sub load {
    my ($self, $ref, $spec) = @_;
    $self->guard;
    $spec //= {};
    my $entry = $self->declare($ref, $spec);
    return $entry if 'declared' ne $entry->{status};   # idempotent trivially

    # PRESENCE, NOT TRUTH: an empty options map must CLEAR what the
    # instance was declared with.
    $entry->{options} = $spec->{options} if defined $spec->{options};
    my $ok = eval { $self->run($entry, 'define', 'define'); 1 };
    if (!$ok) {
        my $err = $@;
        $entry->{status} = 'failed';
        die $err;
    }
    $entry->{status} = 'loaded';

    # AT LOAD, and before anything runs: a cycle through restart-causing
    # requirements does not settle, and the only safe time to report a
    # non-terminating reconcile is before it starts (section 11.3).
    # `provides` is populated by `define`, which has just run, so this is
    # the first moment the graph is complete.
    $ok = eval { checkcycle($self->graphnodes); 1 };
    if (!$ok) {
        my $err = $@;
        $entry->{status} = 'failed';
        die $err;
    }
    return $entry;
}

# The requirement graph as plain data, for the pure detector.
sub graphnodes {
    my ($self) = @_;
    my @out;
    for my $r (sortedkeys($self->{inst})) {
        my $entry = $self->{inst}{$r};
        push @out, {
            ref => $r,
            provides => [ map { $_->{name} } @{ $entry->{provides} } ],
            requires => requirements($entry->{options}),
        };
    }
    return \@out;
}

sub activate {
    my ($self, $ref) = @_;
    $self->guard;
    my $entry = $self->need($ref);
    return $entry if 'live' eq $entry->{status};   # no-op returning success

    fail_with('plugin_bad_state', "instance has failed: $entry->{ref}",
              { ref => $entry->{ref} })
        if 'failed' eq $entry->{status};
    # Section 9.6: `active: false` bars the instance from running, and the
    # bar is on the INSTANCE rather than on the apply that set it. `ready`
    # reaches this through `activate`, so one guard covers both verbs the
    # design names.
    fail_with('plugin_inactive',
              "instance is barred by active: false: $entry->{ref}",
              { ref => $entry->{ref} })
        if $entry->{barred};
    $self->load($entry->{ref}) if 'declared' eq $entry->{status};

    # A declared requirement that is not live means `pending`: activation
    # is a STANDING REQUEST, not a one-shot event.
    my $unmet = $self->unmetof($entry);
    if (@$unmet) {
        $entry->{unmet} = $unmet;
        $entry->{status} = 'pending';
        return $entry;
    }

    my $ok = eval { $self->run($entry, 'activate', 'activate'); 1 };
    if (!$ok) {
        my $err = $@;
        # Unwind whatever the partial activation captured, in reverse.
        $self->unwind($entry);
        $entry->{status} = 'failed';
        die $err;
    }
    # Section 11.4: THE SELECTION IS MADE HERE, once, and remembered. Every
    # later question - the cascade, `hold`, `unmet` - reads it back rather
    # than re-ranking, which is what "always-reluctant" means.
    $self->chosen($entry, $_, 1) for @{ requirements($entry->{options}) };
    $entry->{status} = 'live';
    $self->reconcile;
    return $entry;
}

sub deactivate {
    my ($self, $ref) = @_;
    $self->guard;
    my $entry = $self->need($ref);
    return $entry if 'loaded' eq $entry->{status} || 'declared' eq $entry->{status};

    # Section 5.2: `unload` is THE ONLY TRANSITION OUT OF `failed`.
    fail_with('plugin_bad_state', "instance has failed: $entry->{ref}",
              { ref => $entry->{ref} })
        if 'failed' eq $entry->{status};

    if ('pending' eq $entry->{status}) {
        # DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section 5.2).
        # It never reached activate, so it holds no scope and no live
        # bindings; running the definition's deactivate there would be
        # teardown without matching setup, which plugins are not written to
        # survive and which could fail an instance that had done nothing
        # wrong. It cannot fail.
        $entry->{status} = 'loaded';
        $entry->{unmet} = [];
        return $entry;
    }

    $self->held($entry);
    $self->cascade($entry, {});

    my $ok = eval { $self->run($entry, 'deactivate', 'deactivate'); 1 };
    if (!$ok) {
        my $err = $@;
        $self->unwind($entry);
        $entry->{status} = 'failed';
        die $err;
    }
    $self->releasecheck($entry, $self->unwind($entry));
    $entry->{status} = 'loaded';
    $self->reconcile;
    return $entry;
}

sub unload {
    my ($self, $ref) = @_;
    $self->guard;
    my $entry = $self->need($ref);
    if ('live' eq $entry->{status} || 'pending' eq $entry->{status}) {
        if ('live' eq $entry->{status}) {
            $self->held($entry);
            $self->cascade($entry, {});
            my $ok = eval { $self->run($entry, 'deactivate', 'deactivate'); 1 };
            if (!$ok) {
                my $err = $@;
                # Section 5.2: ANY failure during a transition lands the
                # instance in `failed`, with the scope STILL FULLY UNWOUND
                # - and the instance STAYS REGISTERED, because `failed` is
                # a state an operator has to be able to see.
                $self->unwind($entry);
                $entry->{status} = 'failed';
                die $err;
            }
            $self->releasecheck($entry, $self->unwind($entry));
        }
        $entry->{status} = 'loaded';
    }
    if ('loaded' eq $entry->{status} || 'failed' eq $entry->{status}) {
        my $ok = eval { $self->run($entry, 'close', 'close'); 1 };
        my $err = $@;
        delete $self->{inst}{ $entry->{ref} };
        die $err if !$ok;
        return;
    }
    delete $self->{inst}{ $entry->{ref} };
    return;
}

# Runs the whole forward path in one call (section 5.1).
sub ready {
    my ($self, $ref) = @_;
    $self->guard;
    my $r = canon_ref($ref);
    $self->declare($r) if !exists $self->{inst}{$r};
    $self->load($r) if 'declared' eq $self->{inst}{$r}{status};
    return $self->activate($r);
}

# Bindings go live only when activation succeeds (section 8.1), so the
# teardown is the exact inverse: reverse order, always. Returns the errors
# the scope raised. Section 8.3: "A failing release does not stop the rest.
# Every entry runs, in reverse order, whatever any of them does; the errors
# are collected and raised as one `plugin_release_failed`."
#
# A selection belongs to ONE activation (section 11.4). Leaving `live` by
# any door drops it, so the next activation ranks afresh - keeping it would
# make a consumer prefer a provider it never actually ran against.
sub unwind {
    my ($self, $entry) = @_;
    $entry->{selected} = {};
    my @errors;
    for my $fn (reverse @{ $entry->{scope} }) {
        my $ok = eval { $fn->(); 1 };
        push @errors, $@ if !$ok;
    }
    $entry->{scope} = [];
    return \@errors;
}

# Section 8.3: "A failed release ends the instance in `failed`, exactly as
# a failed callback does (5.2) - a release that raised may have leaked, and
# an instance that may be holding resources it cannot account for must not
# be reactivated."
sub releasecheck {
    my ($self, $entry, $errors) = @_;
    return if !@$errors;

    $entry->{status} = 'failed';
    my @causes = map { my $c = "$_"; $c =~ s/\s+\z//; $c } @$errors;
    fail_with('plugin_release_failed',
              "release failed for $entry->{ref}: " . join('; ', @causes),
              { ref => $entry->{ref}, cause => \@causes });
}

# A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1). A bare
# string is shorthand for `{name}`. A ref satisfies too, because a host
# that genuinely needs a specific instance should not have to invent a
# capability for it.
sub unmetof {
    my ($self, $entry) = @_;
    my @out;
    for my $req (@{ requirements($entry->{options}) }) {
        next if !gatesactivation($req);
        next if @{ $self->providersof($req) };
        push @out, $req->{name};
    }
    return \@out;
}

# Section 11.4's always-reluctant selection, and the ONE place a provider
# is picked for a live instance. If this instance already selected a
# provider for `req` and that provider is STILL a candidate, it keeps it -
# a better-ranked newcomer does not take it.
#
# `remember` is false for the questions asked ABOUT an instance rather than
# BY it: introspection must not create a binding.
sub chosen {
    my ($self, $entry, $req, $remember) = @_;
    my $cands = $self->providersof($req);
    return undef if !@$cands;

    my $held = $entry->{selected}{ $req->{name} };
    if (defined $held) {
        return $held if grep { $_->{ref} eq $held } @$cands;
    }

    $entry->{selected}{ $req->{name} } = $cands->[0]{ref} if $remember;
    return $cands->[0]{ref};
}

sub boundproviders {
    my ($self, $entry) = @_;
    my @out;
    my %seen;
    for my $req (@{ requirements($entry->{options}) }) {
        next if !restartsonloss($req);
        my $ref = $self->chosen($entry, $req, 0);
        next if !defined $ref || $seen{$ref}++;
        push @out, $ref;
    }
    return \@out;
}

# Live instances whose selected provider is `ref` and which would be
# restarted by losing it.
sub consumersof {
    my ($self, $ref) = @_;
    my @out;
    for my $r (sortedkeys($self->{inst})) {
        my $c = $self->{inst}{$r};
        next if $r eq $ref || 'live' ne $c->{status};
        push @out, $r if grep { $_ eq $ref } @{ $self->boundproviders($c) };
    }
    return \@out;
}

# Section 11.3's `hold` asks a DIFFERENT question from the cascade, and
# reading it off `consumersof` answered the cascade's.
#
# The cascade wants the edges that RESTART - mandatory-static and
# optional-static - because a restart is what it performs. `hold` says
# "deactivating a REQUIRED instance is `plugin_dependency_held`", and
# required is cardinality: `gatesactivation`, not `restartsonloss`. The two
# sets differ in both directions and each difference was a real bug.
#
# A MANDATORY-DYNAMIC consumer was excluded, so the strictest policy let a
# provider go that a live consumer could not do without - `dynamic`
# promises survival of a SWAP, and under `hold` there is no swap, so the
# consumer falls back to `pending`.
#
# An OPTIONAL-STATIC consumer was included, so `hold` refused a
# deactivation on behalf of an instance that had said in writing it does
# not need the thing.
sub holdersof {
    my ($self, $ref) = @_;
    my @out;
    for my $r (sortedkeys($self->{inst})) {
        my $c = $self->{inst}{$r};
        next if $r eq $ref || 'live' ne $c->{status};
        for my $req (@{ requirements($c->{options}) }) {
            next if !gatesactivation($req);
            next if ($self->chosen($c, $req, 0) // '') ne $ref;
            push @out, $r;
            last;
        }
    }
    return \@out;
}

sub providersof {
    my ($self, $req) = @_;
    my @cands;
    my $want = canon($req->{name});
    for my $ref (sortedkeys($self->{inst})) {
        my $target = $self->{inst}{$ref};
        next if 'live' ne $target->{status};

        # A ref satisfies directly.
        if ($ref eq $want) {
            push @cands, { ref => $ref, pos => $target->{pos},
                           provides => { name => $req->{name} } };
            next;
        }
        for my $prov (@{ $target->{provides} }) {
            push @cands, { ref => $ref, pos => $target->{pos}, provides => $prov }
                if ($prov->{name} // '') eq $req->{name};
        }
    }
    return resolve_capability($req, \@cands);
}

# CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).
#
# The cascade is part of the provider's own deactivation and runs BEFORE
# the provider's `deactivate` callback and scope unwind, so a consumer's
# teardown can still call the thing it depends on - flushing a buffer to
# the store it is about to lose is exactly what a `deactivate` callback is
# for, and a cascade that fired after the provider was already gone would
# make that impossible.
sub cascade {
    my ($self, $provider, $seen) = @_;
    return if $seen->{ $provider->{ref} };

    $seen->{ $provider->{ref} } = 1;

    for my $r (@{ $self->consumersof($provider->{ref}) }) {
        my $consumer = $self->{inst}{$r};
        next if 'live' ne $consumer->{status};

        $self->cascade($consumer, $seen);       # deepest-first
        my $bad = !eval { $self->run($consumer, 'deactivate', 'deactivate'); 1 };
        my $errors = $self->unwind($consumer);
        if ($bad || @$errors) {
            # Section 5.2: ANY failure during a transition lands the
            # instance in `failed`. Marking it `pending` handed it straight
            # back to `reconcile`, which would activate it again the moment
            # the provider returned.
            $consumer->{status} = 'failed';
            next;
        }
        $consumer->{status} = 'pending';
        $consumer->{unmet} = $self->unmetof($consumer);
    }
    return;
}

# The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED
# TEARDOWN. In a bulk operation that is removing the holders too - `close`,
# or an `apply` plan whose own steps deactivate them - it is suspended for
# exactly those holders, and the teardown still runs consumers before
# providers.
sub held {
    my ($self, $entry) = @_;
    return if 'hold' ne $self->{dependency};
    return if $self->{coordinated};

    my $holders = $self->holdersof($entry->{ref});
    return if !@$holders;

    fail_with('plugin_dependency_held',
              "instance is required by live consumers: $entry->{ref}",
              { ref => $entry->{ref}, holders => $holders });
}

# EAGER reconciliation: run to a fixed point rather than scheduling.
#
# Two directions, and both are the reason `pending` exists. Activation is a
# STANDING REQUEST, not a one-shot event.
sub reconcile {
    my ($self) = @_;
    my $moved = 1;
    my $rounds = 0;
    while ($moved) {
        $moved = 0;
        $rounds++;
        last if $rounds > 1000;

        # Losses first, so a cascade settles in one pass rather than
        # alternating with re-activations.
        for my $r (sortedkeys($self->{inst})) {
            my $entry = $self->{inst}{$r};
            next if 'live' ne $entry->{status};

            my @lost = grep {
                gatesactivation($_) && !@{ $self->providersof($_) }
            } @{ requirements($entry->{options}) };
            next if !@lost;
            # POLICY IS PER REQUIREMENT, not per instance (section 11.3). A
            # `dynamic` requirement whose provider is gone leaves the
            # consumer LIVE and notified.
            next if !grep { restartsonloss($_) } @lost;

            my $bad = !eval { $self->run($entry, 'deactivate', 'deactivate'); 1 };
            my $errors = $self->unwind($entry);
            if ($bad || @$errors) {
                $entry->{status} = 'failed';
                $moved = 1;
                next;
            }
            $entry->{status} = 'pending';
            $entry->{unmet} = $self->unmetof($entry);
            $moved = 1;
        }

        for my $r (sortedkeys($self->{inst})) {
            my $entry = $self->{inst}{$r};
            next if 'pending' ne $entry->{status};
            next if @{ $self->unmetof($entry) };

            if (eval { $self->run($entry, 'activate', 'activate'); 1 }) {
                $entry->{status} = 'live';
                $entry->{unmet} = [];
                $moved = 1;
            }
            else {
                $self->unwind($entry);
                $entry->{status} = 'failed';
                $moved = 1;
            }
        }
    }
    return;
}

# --- ordering ---------------------------------------------------------

sub order {
    my ($self, $point) = @_;
    # Sorted by declaration SEQUENCE, which is what makes the section 7
    # sort's fall-through deterministic in a language whose maps have no
    # insertion order. Section 7 breaks ties by `pos`; two instances CAN
    # share one - `declare` defaults `pos` to the registry size, so an
    # unload followed by a fresh declare reuses a surviving instance's -
    # and past that this was falling through to hash order. `seq` is that
    # order, made explicit.
    my @live = grep { 'live' eq $_->{status} } map { $self->{inst}{$_} }
        sortedkeys($self->{inst});
    my $sorted = stable_sort_by(\@live, sub { [ $_[0]->{seq} ] });
    my @bindings = map {
        { ref => $_->{ref}, pos => $_->{pos}, order => $_->{order} }
    } @$sorted;
    my $spec = defined $point ? $self->{points}{$point} : undef;
    return resolve_order(\@bindings, ismap($spec) ? $spec->{pin} : undef);
}

# --- points -----------------------------------------------------------

# Live bindings on a point, in resolved order. Recomputed on any change to
# the live set (section 7) rather than cached at startup - the bug a host
# discovers only when something deactivates in production.
sub bound {
    my ($self, $point) = @_;
    my @out;
    for my $ref (@{ $self->order($point) }) {
        my $entry = $self->{inst}{$ref};
        # The band is the INSTANCE's ordering block (section 7), stamped by
        # the host. A plugin passing its own would be ranking itself above
        # the order its document declared.
        my $block = ismap($entry->{order}) ? $entry->{order} : {};
        my $band = 'num' eq jsontype($block->{band}) ? int($block->{band}) : 0;
        for my $b (@{ $entry->{bindings} }) {
            push @out, { %$b, band => $band } if $b->{point} eq $point;
        }
    }
    return \@out;
}

sub pointspec {
    my ($self, $point, $want) = @_;
    my $spec = $self->{points}{$point};
    fail_with('plugin_point_unknown', "no such point: $point", { point => $point })
        if !defined $spec;
    my $kind = $spec->{kind};
    if ('hook' eq $want) {
        # A point with no declared kind is a hook, which is what makes `{}`
        # the minimal point declaration.
        fail_with('plugin_point_kind', "point is not a hook: $point",
                  { point => $point, kind => $kind })
            if defined $kind && 'hook' ne $kind;
        return $spec;
    }
    fail_with('plugin_point_kind', "point is not a $want: $point",
              { point => $point, kind => $kind })
        if !defined $kind || $kind ne $want;
    return $spec;
}

sub emit {
    my ($self, $point, $arg) = @_;
    my $spec = $self->pointspec($point, 'hook');
    return point_emit($self->bound($point), $spec->{mode} // 'emit', $arg);
}

sub call {
    my ($self, $point, @args) = @_;
    my $spec = $self->pointspec($point, 'chain');
    my $base = $spec->{base} // sub { $_[0] };
    return compose($self->bound($point), $base)->(@args);
}

sub provider {
    my ($self, $point, @args) = @_;
    my $spec = $self->pointspec($point, 'provider');
    my $pick = point_provider($self->bound($point), $spec);
    return $spec->{default} if !defined $pick->{winner};
    return $pick->{winner}{fn}->(@args);
}

# The losers are VISIBLE rather than silently ignored (section 6.3).
sub shadowed {
    my ($self, $point) = @_;
    my $spec = $self->{points}{$point};
    return [] if !defined $spec;
    return point_provider($self->bound($point), $spec)->{shadowed};
}

sub exports {
    my ($self, $spec) = @_;
    my @all;
    for my $ref (sortedkeys($self->{inst})) {
        my $entry = $self->{inst}{$ref};
        # Exports of a `loaded` (not live) instance are VISIBLE (11).
        next if 'declared' eq $entry->{status} || 'failed' eq $entry->{status};
        for my $k (sortedkeys($entry->{exports})) {
            push @all, { ref => $ref, key => $k, value => $entry->{exports}{$k} };
        }
    }
    return resolve_export($spec, \@all);
}

# The live providers of a capability, best-first (section 11.1).
sub capability {
    my ($self, $name) = @_;
    my @cands;
    for my $ref (sortedkeys($self->{inst})) {
        my $entry = $self->{inst}{$ref};
        next if 'live' ne $entry->{status};
        for my $prov (@{ $entry->{provides} }) {
            push @cands, { ref => $ref, pos => $entry->{pos}, provides => $prov }
                if ($prov->{name} // '') eq $name;
        }
    }
    return [ map { $_->{ref} } @{ resolve_capability({ name => $name }, \@cands) } ];
}

# --- documents --------------------------------------------------------

# Section 9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
# changed, and move activation state to match", with the stated ordering -
# "deactivations and unloads first (reverse load order), then loads, then
# activations in load order".
#
# FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
# document once, which never looked at instances the new document had
# DROPPED - so an integration removed from a config reload stayed live with
# its bindings and resources.
sub apply {
    my ($self, $doc, $profile) = @_;
    $self->guard;
    $profile //= $self->{opts}{profile};
    my $norm = normalize_config({ doc => $doc, profile => $profile,
                                  keys => $self->{opts}{keys},
                                  reserved => $self->{reserved} });

    my $want = $norm->{order};
    my $defaults = $self->{opts}{defaults} // {};
    my %optionsof;
    for my $ref (@$want) {
        $optionsof{$ref} = resolve_options({
            ref => $ref, doc => $doc, profile => $profile,
            shape => $self->shapeof($ref),
            hostdefaults => $defaults->{ refname($ref) },
        });
    }

    # Should this ref be LIVE after the apply? False for a ref the document
    # declares lazy or inactive AND for one it does not name at all - which
    # is what makes "unload what is gone" and "unload what was toggled off"
    # one rule rather than two.
    my $wantlive = sub {
        my ($ref) = @_;
        my $ent = $norm->{instance}{$ref};
        return defined $ent && truthy($ent->{active})
            && 'eager' eq $ent->{start} ? 1 : 0;
    };

    # --- phase 1: deactivations and unloads, REVERSE load order --------
    my @drop = grep {
        'declared' ne $self->{inst}{$_}{status} && !$wantlive->($_)
    } keys %{ $self->{inst} };
    # Highest `pos` first, ref-descending for a tie, so a consumer declared
    # after its provider goes down first.
    @drop = sort {
        $self->{inst}{$b}{pos} <=> $self->{inst}{$a}{pos} || $b cmp $a
    } @drop;
    $self->unload($_) for @drop;

    # --- phase 2: declare and patch EVERYTHING, in load order ----------
    for my $ref (@$want) {
        my $ent = $norm->{instance}{$ref};
        # NO OPTIONS HERE, and the omission is the fix rather than an
        # oversight. `declare` ADOPTS the options hash it is handed as the
        # instance's own, so passing the resolved hash made target and
        # source THE SAME HASH in the refill below - which cleared its own
        # source and left a first-time instance with no options at all.
        # `declare` makes its own empty hash and the refill fills it, so
        # both paths are now one path.
        $self->declare($ref, { order => $ent->{order}, pos => $ent->{pos} });
        # The bar is REASSERTED ON EVERY APPLY, in both directions - a
        # document that turns the instance back on clears it, which is the
        # whole point of a config switch.
        $self->{inst}{$ref}{barred} = truthy($ent->{active}) ? 0 : 1;
        # REFILL rather than REBIND. A definition's callbacks close over
        # the options hash they were handed at `define`.
        $self->refill($self->{inst}{$ref}{options}, $optionsof{$ref});
        $self->{inst}{$ref}{order} = $ent->{order};
        $self->{inst}{$ref}{pos} = $ent->{pos};
    }

    # --- phase 3: loads, in load order ---------------------------------
    # ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances is
    # twenty map entries and no executed code" (9.6).
    for my $ref (@$want) {
        $self->load($ref) if $wantlive->($ref);
    }

    # --- phase 4: activations, in load order ---------------------------
    for my $ref (@$want) {
        $self->activate($ref) if $wantlive->($ref);
    }
    return;
}

sub shapeof {
    my ($self, $ref) = @_;
    my $definition = $self->{catalog}->get(refname($ref));
    return defined $definition ? $definition->{shape} : undef;
}

sub options {
    my ($self, $ref, $patch) = @_;
    $self->guard;
    my $entry = $self->need($ref);
    my %previous = %{ $entry->{options} };
    my %merged = (%previous, %{ $patch // {} });
    $self->refill($entry->{options}, resolve_options({
        ref => $entry->{ref}, shape => $self->shapeof($entry->{ref}),
        doc => {}, patch => \%merged,
    }));
    return if 'live' ne $entry->{status};

    my $reconfigure = $entry->{def}{reconfigure};
    if ('CODE' eq (ref($reconfigure) // '')) {
        $self->{transition} = 1;
        my $ok = eval {
            $reconfigure->(Voxgig::Plugin::Inst->new($self, $entry),
                           $entry->{options}, \%previous);
            1;
        };
        my $err = $@;
        $self->{transition} = 0;
        die $err if !$ok;
    }
    else {
        # Always correct and sometimes expensive; `reconfigure` exists to
        # make the common case cheap (section 9.4).
        $self->deactivate($entry->{ref});
        $self->activate($entry->{ref});
    }
    return;
}

# Empty the target and refill it, so callers holding the reference see the
# new values.
sub refill {
    my ($self, $target, $source) = @_;
    delete $target->{$_} for keys %$target;
    $target->{$_} = $source->{$_} for keys %{ $source // {} };
    return;
}

sub close {
    my ($self) = @_;
    # A bulk teardown removing the holders too, so `hold` is suspended for
    # exactly those holders (section 11.3) - while the consumers-first
    # cascade still runs, which is the half that matters.
    $self->{coordinated} = 1;
    my $ok = eval {
        $self->unload($_) for reverse sortedkeys($self->{inst});
        1;
    };
    my $err = $@;
    $self->{coordinated} = 0;
    die $err if !$ok;
    return;
}

# The same record section 6.6 gives a plugin about itself, reachable from
# outside for the corpus.
sub positionof {
    my ($self, $ref, $point) = @_;
    my $entry = $self->{inst}{ canon($ref) };
    fail_with('plugin_not_loaded', "no such instance: $ref", { ref => $ref })
        if !defined $entry;
    my $ranked = $self->order($point);
    my $index = -1;
    for my $i (0 .. $#$ranked) {
        if ($ranked->[$i] eq $entry->{ref}) { $index = $i; last }
    }
    return {
        index => $index, count => scalar @$ranked,
        # Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
        # OUTERMOST, so these are not index 0 and index count-1 the other
        # way round.
        outermost => (0 == $index ? !!1 : !!0),
        innermost => ($index == $#$ranked ? !!1 : !!0),
    };
}

sub define {
    my ($self, $definition) = @_;
    $self->{catalog}->add($definition);
    return;
}

sub make_host {
    my ($options) = @_;
    return Voxgig::Plugin::Host->new($options);
}

1;
