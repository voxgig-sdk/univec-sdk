# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Depend.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Depend;

# Dependency cardinality, policy, and the restart graph (section 11.3).
#
# TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
# because only it knows what it can cope with:
#
#                | static (default)          | dynamic
#   -------------|---------------------------|--------------------------
#   mandatory    | unmet -> pending;         | unmet -> pending;
#   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
#                |          recursively      |          notified
#   -------------|---------------------------|--------------------------
#   optional:true| never gates activation;   | never gates activation;
#                | a change deactivates and  | a change is a
#                | reactivates               | notification, nothing else
#
# `dynamic` means the plugin has said, IN WRITING, that it can survive its
# provider being swapped underneath it. It is not the default because most
# plugins cannot, and the cost of wrongly assuming they can is a live
# instance holding a dead reference.
#
# The rebinding-preference axis is deliberately omitted. OSGi has reluctant
# vs greedy and it is a knob every author must understand to read anyone
# else's component; we take always-reluctant. Three axes were more than the
# model can carry across twenty ports.

use strict;
use warnings;
use Voxgig::Plugin::Types qw(fail_with truthy ismap islist sortstrings sortedkeys);
use Voxgig::Plugin::Ref qw(canon);

use Exporter 'import';
our @EXPORT_OK = qw(normrequire requirements restartsonloss gatesactivation
                    restartcausing dependencycycle checkcycle);

# A bare string is shorthand for `{name}`.
sub normrequire {
    my ($raw) = @_;
    return { name => $raw } if !ref $raw;
    return ismap($raw) ? { %$raw } : {};
}

# The requirements a definition declared, normalized.
#
# BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
#
# The instance-level `policy` and `optional` list are how a DOCUMENT states
# the axis without editing the definition, and they apply to every
# requirement. The per-requirement form is the one section 11.1's object
# syntax exists for, and it is strictly more expressive: an instance that
# is `static` on its store and `dynamic` on its metrics cannot be written
# at all at the instance level.
#
# `optional` unions rather than overriding - both spellings are statements
# that this requirement need not gate activation, and there is no reading
# under which one of them means "actually, mandatory".
sub requirements {
    my ($options) = @_;
    $options //= {};
    my $raw = $options->{requires} // [];
    my $marked = $options->{optional} // [];
    my $fallback = $options->{policy};

    my @out;
    for my $item (@$raw) {
        my $req = normrequire($item);
        my $ismarked = islist($marked)
            && grep { defined $req->{name} && $_ eq $req->{name} } @$marked;
        $req->{optional} = !!1 if truthy($req->{optional}) || $ismarked;
        $req->{policy} = $fallback
            if !defined $req->{policy} && defined $fallback;
        push @out, $req;
    }
    return \@out;
}

# Does losing this requirement's SELECTED provider restart the consumer?
# The mandatory ones under `static`, and the `static` optional ones - both
# make a capability change deactivate and reactivate. `dynamic` never
# restarts.
sub restartsonloss {
    my ($req) = @_;
    return 'dynamic' ne ($req->{policy} // 'static') ? 1 : 0;
}

# Does an unmet requirement keep the consumer out of `live`?
#
# Cardinality alone decides this, NOT policy. `dynamic` is a statement
# about surviving a SWAP, not about starting without the thing at all - a
# mandatory-dynamic consumer still waits in `pending` for its first
# provider.
sub gatesactivation {
    my ($req) = @_;
    return truthy($req->{optional}) ? 0 : 1;
}

# Edges that can cause a restart, which is exactly the set a cycle must be
# detected over (section 11.3).
#
# ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
# exclusion was for: two plugins that optionally and dynamically consume
# each other's capabilities both activate happily, neither gates on the
# other, and each is merely notified when the other appears. Nothing
# restarts, so nothing oscillates.
#
# An earlier draft of section 11.3 excluded EVERY optional edge and thereby
# admitted the non-terminating case it was trying to permit.
sub restartcausing {
    my ($req) = @_;
    return (gatesactivation($req) || restartsonloss($req)) ? 1 : 0;
}

# A cycle through restart-causing requirements is
# `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
# because the failure it describes is a non-terminating reconcile and the
# only safe time to report that is before it starts.
#
# The graph is over capabilities, not refs: an edge runs from a consumer to
# EVERY node that provides what it needs, because any of them could be the
# one selected and a cycle through any is a cycle. A node also satisfies
# its own name as a ref (section 11.1), which is why the ref is a provider
# of itself here.
sub dependencycycle {
    my ($nodes) = @_;
    # TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    # matched differently - a capability by its exact name, a ref through
    # the canonical spelling (section 4 rule 5) - and one map keyed by
    # both can only do one of them. Keyed by both and looked up raw, as
    # this was, a cycle spelled `a$`/`b$` found no providers and EVADED
    # the load-time check that exists to catch a non-terminating
    # reconcile.
    my (%bycap, %isref);
    for my $n (@$nodes) {
        $isref{ $n->{ref} } = 1;
        for my $cap (@{ $n->{provides} }) {
            push @{ $bycap{$cap} }, $n->{ref};
        }
    }

    my %edges;
    for my $n (@$nodes) {
        my @out;
        my %seen;
        for my $req (@{ $n->{requires} }) {
            next if !restartcausing($req);
            my @from = @{ $bycap{ $req->{name} } // [] };
            # A node satisfies its own name AS A REF (section 11.1),
            # canonically - exactly what `providersof` does at runtime.
            # `canon` hands back a name no ref could have unchanged, and
            # no instance ref can equal one, so it is the tolerant test.
            my $asref = canon($req->{name});
            push @from, $asref
                if $isref{$asref} && !grep { $_ eq $asref } @from;
            for my $p (@from) {
                next if $p eq $n->{ref} || $seen{$p}++;
                push @out, $p;
            }
        }
        $edges{ $n->{ref} } = [ sortstrings(@out) ];
    }

    # Iterative DFS with an explicit stack: twenty ports, and several of
    # them have no recursion budget worth relying on.
    my ($WHITE, $GREY, $BLACK) = (0, 1, 2);
    my %colour = map { $_->{ref} => $WHITE } @$nodes;

    for my $start (sortedkeys(\%edges)) {
        next if $colour{$start} != $WHITE;

        my @path = ($start);
        my @stack = ([ $start, 0 ]);
        $colour{$start} = $GREY;

        while (@stack) {
            my $top = $stack[-1];
            if ($top->[1] >= scalar @{ $edges{ $top->[0] } }) {
                $colour{ $top->[0] } = $BLACK;
                pop @stack;
                pop @path;
                next;
            }
            my $nxt = $edges{ $top->[0] }[ $top->[1] ];
            $top->[1]++;
            if ($colour{$nxt} == $GREY) {
                # Report the cycle itself, not the walk that found it.
                my $at = 0;
                $at++ while $at < @path && $path[$at] ne $nxt;
                return [ @path[ $at .. $#path ], $nxt ];
            }
            next if $colour{$nxt} == $BLACK;

            $colour{$nxt} = $GREY;
            push @path, $nxt;
            push @stack, [ $nxt, 0 ];
        }
    }
    return undef;
}

# Raise on a cycle, naming it. Separate from the detector so the detector
# stays pure and corpus-testable.
sub checkcycle {
    my ($nodes) = @_;
    my $cycle = dependencycycle($nodes);
    return if !defined $cycle;

    fail_with('plugin_dependency_cycle',
              'requirements cycle: ' . join(' -> ', @$cycle),
              { cycle => $cycle });
}

1;
