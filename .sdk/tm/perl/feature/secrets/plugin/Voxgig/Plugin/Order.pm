# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Order.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Order;

# Ordering (section 7) - one rule, one place.
#
# sdkgen grew two special cases in `makeOptions` (`test`, then `station`)
# and the third was not far off. This sort is the whole replacement, and
# the tiers are in this order for a reason:
#
#   1 constraints   before/after edges, by ref or by name
#   2 bands         integer, lower first, default 0
#   3 declaration   ties break by `pos`
#
# CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both are
# present. A band expresses a genuine cross-cutting layer; a constraint
# expresses a relationship between two specific things; and a band chosen
# by trial and error to fix an ordering bug is a bug wearing a number.

use strict;
use warnings;
use sort 'stable';
use Voxgig::Plugin::Types qw(fail_with jsontype ismap islist sortedkeys stable_sort_by);
use Voxgig::Plugin::Ref qw(refname);

use Exporter 'import';
our @EXPORT_OK = qw(resolve_order order_band order_declared order_targets applypin);

sub resolve_order {
    my ($bindings, $pin) = @_;
    my @nodes = @$bindings;
    my %byref = map { $_->{ref} => $_ } @nodes;

    # Constraints are edges. A constraint naming an ABSENT binding is
    # satisfied VACUOUSLY (section 7) - a plugin ordered `after: 'test'`
    # must load in a host with no test plugin. That is sdkgen's __after__
    # behaviour, kept.
    my %edges = map { $_->{ref} => [] } @nodes;

    for my $b (@nodes) {
        my $block = ismap($b->{order}) ? $b->{order} : {};
        # An ABSENT constraint and an EMPTY LIST are both "no constraint".
        if (order_declared($block->{after})) {
            push @{ $edges{$_} }, $b->{ref}
                for @{ order_targets($block->{after}, \@nodes) };
        }
        if (order_declared($block->{before})) {
            push @{ $edges{ $b->{ref} } }, @{ order_targets($block->{before}, \@nodes) };
        }
    }

    # Stable topological sort. Among ready nodes, band first (lower runs
    # first), then `pos` - the position the DOCUMENT visibly states, not the
    # order instances happened to load and not the incarnation `seq`.
    my %indeg = map { $_->{ref} => 0 } @nodes;
    for my $tos (values %edges) {
        $indeg{$_}++ for @$tos;
    }

    my @out;
    my $ready = [ grep { 0 == $indeg{ $_->{ref} } } @nodes ];

    while (@$ready) {
        $ready = stable_sort_by($ready,
            sub { [ order_band($_[0]), $_[0]->{pos} // 0 ] });
        my $nxt = shift @$ready;
        push @out, $nxt->{ref};
        for my $to (@{ $edges{ $nxt->{ref} } }) {
            $indeg{$to}--;
            push @$ready, $byref{$to} if 0 == $indeg{$to};
        }
    }

    if (@out != @nodes) {
        my %placed = map { $_ => 1 } @out;
        my @stuck = map { $_->{ref} } grep { !$placed{ $_->{ref} } } @nodes;
        fail_with('plugin_order_cycle',
                  'before/after constraints cycle: ' . join(' -> ', @stuck),
                  { cycle => \@stuck });
    }

    return applypin(\@out, \%edges, $pin);
}

sub order_band {
    my ($binding) = @_;
    my $block = ismap($binding->{order}) ? $binding->{order} : {};
    my $value = $block->{band};
    # A JSON number, not a numeric string and not a boolean: perl would read
    # `"3"` and `!!1` as 3 and 1 in arithmetic, and section 7's band is an
    # integer the document wrote as one.
    return 'num' eq jsontype($value) ? int($value) : 0;
}

# Was a constraint stated? An absent value and an EMPTY LIST are both
# no-constraint - and an empty list is TRUE in ruby and FALSE in php, which
# is exactly why this tests the spelling rather than the truth of it.
sub order_declared {
    my ($spec) = @_;
    return 0 if !defined $spec;
    if (islist($spec)) {
        return (grep { '' ne $_ } @$spec) ? 1 : 0;
    }
    return '' ne $spec ? 1 : 0;
}

# One spelling or a LIST of them. A list fans out to the UNION of what each
# names, so after: ['a','b'] means after BOTH, and the same instance named
# twice - once by name, once by ref - is one edge.
sub order_targets {
    my ($spec, $nodes) = @_;
    my @specs = islist($spec) ? @$spec : ($spec);
    my @hit;
    my %seen;
    for my $one (@specs) {
        for my $b (@$nodes) {
            next if $seen{ $b->{ref} };
            if ($b->{ref} eq $one || refname($b->{ref}) eq $one) {
                $seen{ $b->{ref} } = 1;
                push @hit, $b->{ref};
            }
        }
    }
    return \@hit;
}

# A PIN IS NOT A CONSTRAINT (section 7).
#
# Constraints and bands are negotiable by definition - they are what
# plugins and documents say they want, and the sort's job is to satisfy
# them all. A pin is the host stating a structural invariant of its own
# architecture, which is a different kind of claim and must not lose a tie
# to a document.
#
# So a pin PLACES the binding at the named end, and an ordering that would
# move it away is `plugin_order_pinned` - rejected, not honoured into a
# broken wrap.
sub applypin {
    my ($order, $edges, $pin) = @_;
    return $order if !defined $pin;

    my @out = @$order;

    # SORTED, not insertion order. A pin map is data - it can arrive from a
    # host's own construction options in any order, and two names pinned to
    # the same end are order-sensitive (`{b:'first', a:'first'}` and
    # `{a:'first', b:'first'}` give different results). A perl hash has no
    # order at all, which makes leaving it unstated worse here than
    # anywhere else.
    for my $name (sortedkeys($pin)) {
        my $want = $pin->{$name};
        my $idx;
        for my $i (0 .. $#out) {
            if (refname($out[$i]) eq $name) { $idx = $i; last }
        }
        next if !defined $idx;

        # `first`/`outermost` is index 0; `last`/`innermost` is the end.
        # Section 6.2 makes the first chain binding outermost, which is why
        # the vocabulary is positional and why the two spellings pair this
        # way.
        my $wantfirst = ('first' eq $want || 'outermost' eq $want) ? 1 : 0;
        my ($ref) = splice(@out, $idx, 1);
        if ($wantfirst) { unshift @out, $ref } else { push @out, $ref }
    }

    # Now check that the placement did not break a constraint. This is the
    # half that makes a pin a rejection rather than an override: the host
    # wins on position, but it does not get to silently discard a
    # relationship a plugin declared.
    my %at;
    $at{ $out[$_] } = $_ for 0 .. $#out;
    for my $from (sortedkeys($edges)) {
        for my $to (@{ $edges->{$from} }) {
            next if $at{$from} <= $at{$to};
            fail_with('plugin_order_pinned',
                      'a pin would move a binding an ordering constrains: '
                      . "$from must precede $to",
                      { before => $from, after => $to });
        }
    }

    return \@out;
}

1;
