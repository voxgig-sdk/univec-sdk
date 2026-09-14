# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Capability.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Capability;

# Capabilities (section 11.1).
#
# A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF - because it is a
# dependency on something that can do the job, and which instance is doing
# it is exactly the configuration detail a plugin must not care about.
#
# But A BINDING IS TO AN INSTANCE, not to a capability, which is what
# decides behaviour when the bound provider leaves while another match
# remains.

use strict;
use warnings;
use sort 'stable';
use Voxgig::Plugin::Types qw(jsontype ismap islist stable_sort_by);
use Voxgig::Plugin::Version qw(satisfiesq);

use Exporter 'import';
our @EXPORT_OK = qw(resolve_capability matches matchvalue samescalar rank_key);

# Rank the matching live providers and return them best-first: highest
# `version`, then LOWEST `priority` (default 0), then declaration position
# `pos` ascending.
#
# `priority` is a field on the capability rather than section 7's `order`
# band, because bands live on POINT BINDINGS: a provider may have several
# bindings with different bands, or none at all, so a rank reaching for one
# would be undefined in the common case.
#
# Without a total rank, "any provider satisfies" is true of the GRAPH and
# useless to the PLUGIN - two ports could bind different `store` instances,
# both resolve green, and behave differently, which is precisely the
# divergence a shared corpus exists to catch.
sub resolve_capability {
    my ($req, $candidates) = @_;
    my @hits = grep { matches($req, $_->{provides} // {}) } @$candidates;
    return stable_sort_by(\@hits, \&rank_key);
}

sub rank_key {
    my ($cand) = @_;
    my $prov = $cand->{provides} // {};
    my $version = $prov->{version};
    # An ABSENT version sorts LAST, whatever the other is - "no version"
    # loses to every version rather than being read as 0.0.0. The leading
    # flag is what expresses that in a sort KEY rather than a comparator.
    my $parts = defined $version ? version_parts($version) : [ 0, 0, 0 ];
    return [
        defined $version ? 0 : 1,
        [ map { -$_ } @$parts ],
        $prov->{priority} // 0,
        $cand->{pos} // 0,
    ];
}

sub matches {
    my ($req, $prov) = @_;
    return 0 if !samescalar($req->{name}, $prov->{name});

    if (defined $req->{range}) {
        return 0 if !defined $prov->{version};
        return 0 if !satisfiesq($prov->{version}, $req->{range});
    }

    # `match` is checked against the provider's `attrs`, key by key. A key
    # the provider does not carry is a miss, not a pass: a requirement
    # asking for `transactional: true` must not be satisfied by a provider
    # that never said.
    if (defined $req->{match}) {
        my $attrs = $prov->{attrs} // {};
        for my $k (keys %{ $req->{match} }) {
            return 0 if !ismap($attrs) || !exists $attrs->{$k};
            return 0 if !matchvalue($req->{match}{$k}, $attrs->{$k});
        }
    }

    return 1;
}

# PARTIAL MATCH, RECURSING INTO MAPS (section 11.1).
#
# Section 11.1 defines `match` as "a partial match against `attrs`, with
# exactly the semantics voxgig/struct and the omni corpus already define
# for `match` - every leaf in the requirement must be present and equal in
# the capability, keys not mentioned are not checked."
#
# Equality is by JSON TYPE as well as value, and PERL HAS NO JSON TYPES:
# `1 == "1"` and `1 == !!1` are both true here, and the corpus pins both as
# different (capability/match). So every leaf goes through `samescalar`,
# which asks `jsontype` first and compares second.
#
# A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset.
sub matchvalue {
    my ($want, $got) = @_;

    if (ismap($want)) {
        return 0 if !ismap($got);
        for my $k (keys %$want) {
            return 0 if !exists $got->{$k};
            return 0 if !matchvalue($want->{$k}, $got->{$k});
        }
        return 1;
    }

    if (islist($want)) {
        return 0 if !islist($got) || @$want != @$got;
        for my $i (0 .. $#$want) {
            return 0 if !matchvalue($want->[$i], $got->[$i]);
        }
        return 1;
    }

    return samescalar($want, $got);
}

# JSON equality on two scalars: same type, then same value.
#
# THE TYPE TEST IS THE WHOLE POINT. Perl compares `1`, `"1"` and `!!1` as
# equal under `==` and the first two under `eq`; the corpus says all three
# are different, and `capability/match` has an entry for each direction.
sub samescalar {
    my ($want, $got) = @_;
    my $tw = jsontype($want);
    my $tg = jsontype($got);
    return 0 if $tw ne $tg;
    return 1 if 'null' eq $tw;
    return (($want ? 1 : 0) == ($got ? 1 : 0)) ? 1 : 0 if 'bool' eq $tw;
    return $want == $got ? 1 : 0 if 'num' eq $tw;
    return $want eq $got ? 1 : 0;
}

sub version_parts {
    my ($text) = @_;
    return [ map { 0 + $_ } split /\./, "$text" ];
}

1;
