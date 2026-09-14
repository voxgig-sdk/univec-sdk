# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Version.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Version;

# Versions and ranges (section 11.2).
#
# TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a concrete
# version. A requirement declares `range`. A requirement is satisfied when
# the names match, the `match` passes, and:
#
#   the provider's `version` falls inside the requirement's `range`.
#
# That is the whole rule. There is no third field and no second comparison
# - an earlier draft added a provider-side `compat` range, which left three
# values and no statement of how they combine, and three defensible
# readings of one declaration is worse than the ambiguity it was introduced
# to fix.

use strict;
use warnings;
use Voxgig::Plugin::Types qw(fail_with jsontype);

use Exporter 'import';
our @EXPORT_OK = qw(parse_range parse_version satisfies satisfiesq version_cmp);

our $VERSION_RE = qr/\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z/;

# A COMPONENT IS BOUNDED, and the bound is the model's, not the host
# language's. Perl's integers are 64-bit and JavaScript's stop being exact
# past 2**53, so `9223372036854775808.0.0` parsed to one value here and a
# rounded one there. 2**31-1 is the smallest bound every target language
# holds exactly, which makes it the model's.
our $COMPONENT_MAX = 2147483647;

# `0 + $digits` promotes past the integer range into a float rather than
# wrapping, so a twenty-digit component lands far above the bound and the
# check fires on it. A LENGTH GUARD WOULD BE DEAD CODE.
sub component {
    my ($digits, $whole, $field) = @_;
    my $value = 0 + $digits;
    fail_with('plugin_bad_range',
              "version component out of range in $whole: $digits",
              { $field => $whole })
        if $COMPONENT_MAX < $value;
    return $value;
}

# Two forms and no more (section 11.2):
#
#   '2.1'    >= 2.1.0 and < 3.0.0
#   '~2.1'   >= 2.1.0 and < 2.2.0
sub parse_range {
    my ($range) = @_;
    if ('str' ne jsontype($range) || '' eq $range) {
        my $shown = defined $range && !ref $range ? $range : '(not a range)';
        fail_with('plugin_bad_range', "invalid range: $shown", { range => $range });
    }

    my $tilde = 0 == index($range, '~');
    my $body = $tilde ? substr($range, 1) : $range;
    my @m = $body =~ $VERSION_RE;
    fail_with('plugin_bad_range', "invalid range: $range", { range => $range })
        if !@m;

    my $major = component($m[0], $range, 'range');
    my $minor = defined $m[1] ? component($m[1], $range, 'range') : 0;
    my $patch = defined $m[2] ? component($m[2], $range, 'range') : 0;

    return {
        lo => [ $major, $minor, $patch ],
        hi => $tilde ? [ $major, $minor + 1, 0 ] : [ $major + 1, 0, 0 ],
    };
}

sub parse_version {
    my ($version) = @_;
    if ('str' ne jsontype($version)) {
        my $shown = defined $version && !ref $version ? $version : '(not a version)';
        fail_with('plugin_bad_range', "invalid version: $shown",
                  { version => $version });
    }
    my @m = $version =~ $VERSION_RE;
    fail_with('plugin_bad_range', "invalid version: $version",
              { version => $version })
        if !@m;
    return [
        component($m[0], $version, 'version'),
        defined $m[1] ? component($m[1], $version, 'version') : 0,
        defined $m[2] ? component($m[2], $version, 'version') : 0,
    ];
}

# The one satisfaction predicate: lo <= version < hi.
sub satisfies {
    my ($version, $range) = @_;
    my $v = parse_version($version);
    my $r = parse_range($range);
    return version_cmp($v, $r->{lo}) >= 0 && version_cmp($v, $r->{hi}) < 0
        ? !!1 : !!0;
}

# satisfies for the internal callers that treat an unparseable version or
# range as "does not satisfy" - Capability and Graph, both of which run
# over data the corpus has already admitted.
sub satisfiesq {
    my ($version, $range) = @_;
    my $ok = eval { satisfies($version, $range) };
    return $ok ? 1 : 0;
}

sub version_cmp {
    my ($x, $y) = @_;
    for my $i (0 .. 2) {
        my $l = $x->[$i] // 0;
        my $r = $y->[$i] // 0;
        return $l < $r ? -1 : 1 if $l != $r;
    }
    return 0;
}

1;
