# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Graph.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Graph;

# Whole-graph resolution (section 11.4) - a phase, not a discovery.
#
# "Activate, and wait in `pending` if you must" is correct and, on its own,
# produces a terrible experience: apply twenty instances against a registry
# missing one thing and you get NINETEEN pending rows and no statement of
# what is actually wrong.
#
# `resolve_graph` is a PURE FUNCTION of the registry and the intended
# activation set. No callbacks run, no state changes, nothing is touched.
# It answers for the whole graph at once which instances can be live, and
# for each blocked one THE SPECIFIC REQUIREMENT that is unmet, and why.
#
# The failure mode being designed against is a famous one: OSGi's resolver
# is correct and its diagnostics are legendarily unusable. A resolver that
# says "blocked" without saying WHY has moved the problem rather than
# solved it, so `why` is part of the contract and the corpus pins its
# shape.

use strict;
use warnings;
use Voxgig::Plugin::Types qw(truthy sortstrings sortedkeys);
use Voxgig::Plugin::Ref qw(canon);
use Voxgig::Plugin::Capability qw(resolve_capability matchvalue);
use Voxgig::Plugin::Version qw(satisfiesq);

use Exporter 'import';
our @EXPORT_OK = qw(resolve_graph);

sub resolve_graph {
    my ($nodes) = @_;
    my %byref = map { $_->{ref} => $_ } @$nodes;

    my %resolved;
    my %blocked;

    # Fixed point: a node resolves when every mandatory requirement is met
    # by an ALREADY-RESOLVED provider. Iterating to a fixed point is what
    # makes a provider that is itself blocked propagate, rather than each
    # node being judged against the raw registry.
    my $moved = 1;
    while ($moved) {
        $moved = 0;
        for my $n (@$nodes) {
            next if $resolved{ $n->{ref} };
            next if defined firstunmet($n, \%byref, \%resolved);
            $resolved{ $n->{ref} } = 1;
            $moved = 1;
        }
    }

    for my $n (@$nodes) {
        next if $resolved{ $n->{ref} };
        my $why = firstunmet($n, \%byref, \%resolved);
        $blocked{ $n->{ref} } = $why if defined $why;
    }

    return {
        resolved => [ sortedkeys(\%resolved) ],
        blocked  => [ map { $blocked{$_} } sortedkeys(\%blocked) ],
    };
}

# The FIRST unmet requirement, with the most specific explanation
# available. Order matters: "no provider at all" and "a provider at the
# wrong version" are different problems and a reader must not have to guess
# which they have.
sub firstunmet {
    my ($node, $byref, $resolved) = @_;
    for my $req (@{ $node->{requires} // [] }) {
        next if truthy($req->{optional});

        my $all = graph_candidates($byref, $req->{name});
        if (!@$all) {
            return { ref => $node->{ref}, unmet => $req->{name},
                     why => { kind => 'absent' } };
        }

        my $ok = resolve_capability($req, $all);
        if (@$ok) {
            # A provider exists and matches - but if none of them is itself
            # resolved, this node is blocked BEHIND it, and the chain is
            # the useful answer rather than "unmet".
            next if grep { $resolved->{ $_->{ref} } } @$ok;

            return { ref => $node->{ref}, unmet => $req->{name},
                     why => { kind => 'blocked',
                              chain => [ sortstrings(map { $_->{ref} } @$ok) ] } };
        }

        # Providers exist and none matched. Say which test failed.
        if (defined $req->{range}) {
            my @versions;
            for my $c (@$all) {
                my $have = $c->{provides}{version};
                push @versions, (defined $have ? $have : '(none)')
                    if !defined $have || !satisfiesq($have, $req->{range});
            }
            if (@versions) {
                return { ref => $node->{ref}, unmet => $req->{name},
                         why => { kind => 'version', range => $req->{range},
                                  found => [ sortstrings(@versions) ] } };
            }
        }

        if (defined $req->{match}) {
            for my $c (@$all) {
                my $attrs = $c->{provides}{attrs} // {};
                for my $k (sortedkeys($req->{match})) {
                    next if exists $attrs->{$k}
                        && matchvalue($req->{match}{$k}, $attrs->{$k});

                    return { ref => $node->{ref}, unmet => $req->{name},
                             why => { kind => 'match', failing => $k,
                                      want => $req->{match}{$k},
                                      found => $attrs->{$k} } };
                }
            }
        }

        return { ref => $node->{ref}, unmet => $req->{name},
                 why => { kind => 'absent' } };
    }
    return undef;
}

sub graph_candidates {
    my ($byref, $name) = @_;
    my @out;
    # A NODE SATISFIES ITS OWN REF (section 11.1), and the graph learned
    # it here. Considering only declared capabilities made `resolve`
    # answer `absent` about a provider sitting right there and live -
    # section 11.4's job is explaining the graph the runtime reconciles.
    my $asref = canon($name);
    for my $ref (sortedkeys($byref)) {
        my $node = $byref->{$ref};
        # The ref match WINS OUTRIGHT for that node, as at runtime: one
        # candidate, not two, for a node both named `b` and providing `b`.
        if ($ref eq $asref) {
            push @out, { ref => $node->{ref}, pos => $node->{pos} // 0,
                         provides => { name => $name } };
            next;
        }
        for my $prov (@{ $node->{provides} // [] }) {
            next if ($prov->{name} // '') ne $name;
            push @out, { ref => $node->{ref}, pos => $node->{pos} // 0,
                         provides => $prov };
        }
    }
    return \@out;
}

1;
