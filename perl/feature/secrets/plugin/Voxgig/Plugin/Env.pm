# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Env.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Env;

# Environment overrides (section 9.5) - level 7 of the ladder.
#
# One prefix, so nothing drifts: `VOXGIG_PLUGIN_*`.
#
#   VOXGIG_PLUGIN_PROFILE            the profile name
#   VOXGIG_PLUGIN_<REF>_<PATH>       one option
#   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
#
# THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING OTHERWISE.
# Ref and path are upper-snake with `$` -> `__` and `.` -> `_`. But `_` is
# legal in a name and in a tag, and the mapping folds case, so `retry$fast`
# and `retry__fast` both encode to `RETRY__FAST`.
#
# Rather than restrict a grammar the rest of the stack already uses, the
# host DETECTS THE COLLISION: it encodes every ref it holds, and a key two
# refs claim is `plugin_env_ambiguous`, naming both.

use strict;
use warnings;
use sort 'stable';
use JSON::PP ();
use Scalar::Util qw(looks_like_number);
use Voxgig::Plugin::Types qw(fail_with ismap jsontype sortstrings sortedkeys stable_sort_by);
use Voxgig::Plugin::Ref qw(canon_ref refname);

use Exporter 'import';
our @EXPORT_OK = qw(apply_env encode_ref);

our $ENV_PREFIX = 'VOXGIG_PLUGIN_';

# `retry$fast` -> `RETRY__FAST`.
sub encode_ref {
    my ($ref) = @_;
    my $out = $ref;
    $out =~ s/\$/__/g;
    $out =~ s/\./_/g;
    return uc $out;
}

sub apply_env {
    my ($input) = @_;
    $input //= {};
    my $env = $input->{env} // {};
    my @refs = map { canon_ref($_) } @{ $input->{refs} // [] };
    my $reserved = $input->{reserved} // [];
    my $out = { options => {}, active => [], inactive => [] };

    # Encode every ref the host holds, and refuse a key that two of them
    # claim. Done up front so the collision is reported even when no
    # environment variable exercises it - a latent ambiguity is still an
    # ambiguity, and finding it at deploy time is the failure this exists
    # to prevent.
    my %byencoded;
    push @{ $byencoded{ encode_ref($_) } }, $_ for @refs;
    for my $e (sortedkeys(\%byencoded)) {
        next if 1 >= @{ $byencoded{$e} };
        my @pair = sortstrings(@{ $byencoded{$e} });
        fail_with('plugin_env_ambiguous',
                  "refs collide in the environment encoding as $e: "
                  . join(', ', @pair),
                  { encoded => $e, refs => \@pair });
    }

    # Longest encoded ref first, so `retry$fast` wins over `retry` on
    # `RETRY__FAST_MIN`. Shortest-first would read the tag as a path.
    my $encoded = stable_sort_by([ sortedkeys(\%byencoded) ],
        sub { [ -length $_[0] ] });

    for my $key (sortedkeys($env)) {
        next if 0 != index($key, $ENV_PREFIX);

        my $rest = substr($key, length $ENV_PREFIX);

        if ('PROFILE' eq $rest) {
            $out->{profile} = $env->{$key};
            next;
        }

        if ('ACTIVE' eq $rest || 'INACTIVE' eq $rest) {
            for my $raw (env_split($env->{$key})) {
                my $ref = canon_ref($raw);
                # The reservation covers EVERY input layer (section 9.1).
                # VOXGIG_PLUGIN_INACTIVE=station is easier to set than
                # editing a config file, and INACTIVE has the final word -
                # so guarding documents alone would leave the one lever
                # this mechanism exists to deny wide open.
                env_checkreserved($ref, $reserved);
                push @{ $out->{ 'ACTIVE' eq $rest ? 'active' : 'inactive' } },
                    $ref;
            }
            next;
        }

        my $enc;
        for my $e (@$encoded) {
            if ($rest eq $e || 0 == index($rest, $e . '_')) { $enc = $e; last }
        }
        next if !defined $enc;          # not for any ref this host holds

        my $ref = $byencoded{$enc}[0];
        env_checkreserved($ref, $reserved);

        next if $rest eq $enc;          # a ref with no path sets nothing

        my @path = split /_/, lc substr($rest, length($enc) + 1);

        my $node = $out->{options};
        $node->{$ref} = {} if !ismap($node->{$ref});
        $node = $node->{$ref};
        for my $step (@path[ 0 .. $#path - 1 ]) {
            $node->{$step} = {} if !ismap($node->{$step});
            $node = $node->{$step};
        }
        $node->{ $path[-1] } = env_parsevalue($env->{$key});
    }

    return $out;
}

sub env_split {
    my ($value) = @_;
    my @out;
    for my $part (split /,/, defined $value ? "$value" : '') {
        $part =~ s/\A\s+//;
        $part =~ s/\s+\z//;
        push @out, $part if '' ne $part;
    }
    return @out;
}

sub env_checkreserved {
    my ($ref, $reserved) = @_;
    return if !@$reserved;
    my $name = refname($ref);
    return if !grep { $_ eq $name } @$reserved;

    fail_with('plugin_ref_reserved', "ref is reserved by the host: $ref",
              { ref => $ref });
}

# Values parse as JSON, FALLING BACK TO STRING - so `8080` is a number,
# `true` is a boolean, `{"a":1}` is a map, and `hello` is the string it
# looks like rather than a parse error.
#
# JSON::PP is CORE (since 5.14), so this is not a third-party dependency
# any more than ruby's `json` is; `allow_nonref` is what admits a bare
# scalar at the top level, which RFC 7159 does and JSON::PP's default
# constructor does not.
sub env_parsevalue {
    my ($value) = @_;
    return $value if ref $value;
    my $parsed = eval {
        JSON::PP->new->allow_nonref->decode(defined $value ? $value : '')
    };
    return $value if $@;

    # A JSON INTEGER WIDER THAN PERL'S IV COMES BACK AS A STRING. JSON::PP
    # cannot hold `922337203685477580812345` in an IV or an NV without
    # loss, so it hands back the digits as a plain scalar - and `jsontype`
    # then reads `str` where the canonical's `JSON.parse` publishes a
    # number. Numify it: javascript loses the same precision at 2**53 and
    # still calls the result a number, so this agrees with the canonical
    # on the TYPE, which is what the ladder and every capability
    # comparison actually read.
    if ('str' eq jsontype($parsed) && $value =~ /\A\s*-?[0-9]/ && looks_like_number($value)) {
        return 0 + $parsed;
    }
    return $parsed;
}

1;
