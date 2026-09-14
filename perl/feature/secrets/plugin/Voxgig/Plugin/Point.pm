# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Point.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Point;

# Extension points (section 6). Three kinds, chosen because they are what
# the two existing systems actually needed, and no more.
#
# A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
# deactivation possible: sdkgen's `utility.fetcher = wrapped` is not
# undoable, but "this instance holds slot 3 of the request chain" is
# undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
# paper called *Listeners Considered Harmful*, and for exactly this reason.

use strict;
use warnings;
use sort 'stable';
use Voxgig::Plugin::Types qw(fail_with truthy sortstrings stable_sort_by);

use Exporter 'import';
our @EXPORT_OK = qw(point_emit compose point_provider);

# Section 6.1: "fan-out" is not one answer but four. In a language with
# asynchrony, "call every binding" hides a decision - start them all and
# wait, await each in turn, or do not wait - and a design that leaves it
# unsaid gets four different answers from four ports, in the concurrency
# behaviour of production code no corpus entry happens to cover.
our @MODES = qw(emit parallel serial bail);

# Fan-out. Return values are ignored except in `bail`.
sub point_emit {
    my ($bindings, $mode, $arg) = @_;

    if ('bail' eq $mode) {
        # Stops at the first binding that RETURNS A VALUE - the "handled,
        # stop" case. An UNDEF RETURN DECLINES (section 6.1): perl has one
        # way to say nothing, and the model's rule is written to that
        # rather than to JavaScript's null/undefined pair. `defined`, NOT
        # truth - `0`, `""` and `false` are values.
        for my $b (@$bindings) {
            my $v = $b->{fn}->($arg);
            return $v if defined $v;
        }
        return undef;
    }

    my @errors;
    for my $b (@$bindings) {
        my $ok = eval { $b->{fn}->($arg); 1 };
        next if $ok;
        my $err = $@;
        # `emit` raises synchronously; the collecting modes gather.
        die $err if 'emit' eq $mode;
        push @errors, $err;
    }
    return 'emit' eq $mode ? undef : \@errors;
}

# Composition: b1(b2(b3(base))), FIRST BINDING OUTERMOST (section 6.2).
#
# Recomputed by the host whenever the live set changes, and cached between
# changes. Plugins receive `next` as an argument; they never see or store
# the previous value of anything. A plugin that stashes `next` and calls it
# after deactivation is a bug the host cannot prevent, and this says so
# rather than pretending otherwise.
sub compose {
    my ($bindings, $base) = @_;
    my $nxt = $base;
    for (my $i = $#$bindings; $i >= 0; $i--) {
        # Fresh lexicals per iteration, so each layer closes over its own
        # pair - perl gives that for free where ruby's blocks do not.
        my $fn = $bindings->[$i]{fn};
        my $inner = $nxt;
        $nxt = sub { return $fn->($inner, @_) };
    }
    return $nxt;
}

# At most one live implementation (section 6.3). The winner is the highest
# band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
# silently ignored.
sub point_provider {
    my ($bindings, $spec) = @_;
    return { winner => undef, shadowed => [] } if !@$bindings;

    if (truthy($spec->{exclusive}) && 1 < @$bindings) {
        my @refs = sortstrings(map { $_->{ref} } @$bindings);
        fail_with('plugin_point_exclusive',
                  'point is exclusive and has ' . scalar(@$bindings)
                  . ' bindings: ' . join(', ', @refs),
                  { refs => \@refs });
    }

    my $ranked = stable_sort_by($bindings,
        sub { [ -$_[0]->{band}, $_[0]->{ref} ] });
    return { winner => $ranked->[0],
             shadowed => [ map { $_->{ref} } @{$ranked}[1 .. $#$ranked] ] };
}

1;
