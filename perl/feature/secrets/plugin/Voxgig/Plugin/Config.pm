# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Config.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Config;

# The declarative document (section 9): normalization, and the ten-level
# precedence ladder.
#
# TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
#
# `normalize_config` normalizes STRUCTURE and ENTRY KEYS. It does not merge
# options, and cannot: section 9.4 makes merge behaviour a property of the
# definition's option SHAPE, which normalization has never seen. A
# normalizer that flattened the option layers would make `$MERGE: append`
# unimplementable at load time, because the layers it must concatenate
# would already be collapsed.
#
# `resolve_options` applies the ladder, and it is the only place that knows
# the shape.

use strict;
use warnings;
use Voxgig::Plugin::Types qw(fail_with jsontype ismap islist truthy
                             clone_value sortstrings sortedkeys);
use Voxgig::Plugin::Ref qw(canon_ref refname);

use Exporter 'import';
our @EXPORT_OK = qw(normalize_config resolve_options check_shape);

our @MERGE_WORDS = qw(replace append);

sub normalize_config {
    my ($input) = @_;
    $input //= {};
    my $doc = $input->{doc} // {};
    my $keys = $input->{keys} // {};
    my $ikey = (ismap($keys) && defined $keys->{instance}) ? $keys->{instance} : 'instance';
    my $dkey = (ismap($keys) && defined $keys->{default}) ? $keys->{default} : 'default';
    my $reserved = $input->{reserved} // [];
    my $profile = $input->{profile};

    # The rename is applied at TWO PLACES AND NO OTHERS: the document root,
    # and every profile.<name> overlay root (section 9.1). A rename applied
    # only at the root would leave `profile.prod.sdk` untranslated and
    # silently drop every environment override the host depends on.
    # Recursing further would be worse: option data is the definition's.
    my $baseinst = $doc->{$ikey};
    my $basedef = $doc->{$dkey} // {};

    my $overlay;
    $overlay = ($doc->{profile} // {})->{$profile} if defined $profile;
    $overlay = {} if !ismap($overlay);
    my $overinst = $overlay->{$ikey};
    my $overdef = $overlay->{$dkey} // {};

    # Entry layers, base then overlay, each as {ref -> entry} plus the
    # order the form implies.
    my $base = config_entries($baseinst);
    my $over = config_entries($overinst);

    for my $group ([ keys %{ $base->{map} } ], [ keys %{ $over->{map} } ],
                   [ keys %$basedef ], [ keys %$overdef ]) {
        config_checkreserved($_, $reserved) for @$group;
    }

    # A PARTIAL ARRAY IS NOT A FILTER (section 9.1). sdkgen learned this
    # the hard way: deriving order from a partial array silently dropped
    # config-activated features. Refs in the base but absent from the
    # overlay still load, in sorted position AFTER the listed ones. A
    # profile may also INTRODUCE a ref the base never declared.
    my @order;
    my %seen;
    for my $r (@{ $over->{order} }, @{ $base->{order} }) {
        next if $seen{$r}++;
        push @order, $r;
    }

    my %instance;
    for my $i (0 .. $#order) {
        my $ref = $order[$i];
        my $b = $base->{map}{$ref};
        my $o = $over->{map}{$ref};

        # MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE RESULT
        # (section 9.3). A safety rule, not a tidiness one: if the overlay
        # had its defaults filled in before merging it would carry a
        # synthesized active:true and overwrite a base's false - silently
        # re-enabling a deliberately disabled integration in production.
        my $active = config_pick($o, 'active', config_pick($b, 'active', !!1));
        my $start  = config_pick($o, 'start',  config_pick($b, 'start', 'eager'));
        my $block  = config_pick($o, 'order',  config_pick($b, 'order', undef));

        # Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
        my @layers;
        my $nm = refname($ref);
        # A LIST ASSIGNMENT FIRST, and it matters. `foreach` ALIASES its
        # list, and aliasing `$overdef->{$nm}` AUTOVIVIFIES that key as
        # undef - which the `default` output below then copies over the
        # base's real value. The bug reads as "the overlay cleared it" and
        # is entirely perl's aliasing; `config/normkeys#root` catches it.
        my @sources = ($basedef->{$nm}, $b, $overdef->{$nm}, $o);
        for my $src (@sources) {
            push @layers, $src->{options} if ismap($src) && exists $src->{options};
        }

        my $ent = { pos => $i, active => $active, start => $start,
                    optionlayers => \@layers };
        $ent->{order} = $block if defined $block;
        $instance{$ref} = $ent;
    }

    # `default` DECLARES NOTHING (section 9.3). It is a base for every
    # instance of that definition; it does not create one, and an entry for
    # a name with no instances is inert rather than an error - which is
    # what makes a shared library of defaults shippable.
    my %defout;
    $defout{$_} = $basedef->{$_} for keys %$basedef;
    $defout{$_} = $overdef->{$_} for keys %$overdef;

    return { instance => \%instance, order => \@order, default => \%defout };
}

# Both document forms reduce to {ref -> entry} plus the order the form
# implies: array POSITION for the array form, sorted refs for the map form.
sub config_entries {
    my ($src) = @_;
    my $out = { map => {}, order => [] };
    return $out if !defined $src;

    if (islist($src)) {
        for my $item (@$src) {
            my $ref = canon_ref($item->{ref});
            $out->{map}{$ref} = $item;
            push @{ $out->{order} }, $ref;
        }
        return $out;
    }

    # Map-form refs arrive as KEYS, through a different path than an array
    # element's `ref` field - and must canonicalize the same way.
    $out->{map}{ canon_ref($_) } = $src->{$_} for keys %$src;
    # Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase refs
    # sort identically under all three, so only mixed input discriminates:
    # '@' is 0x40, uppercase 0x41-0x5A, lowercase 0x61-0x7A. Perl's `cmp`
    # is exactly that.
    $out->{order} = [ sortedkeys($out->{map}) ];
    return $out;
}

# Section 9.1: reservation is all-or-nothing per NAME, so the tagged forms
# go too. A configuration surface that can disable the thing reading it is
# not a surface, it is a trap.
sub config_checkreserved {
    my ($ref, $reserved) = @_;
    return if !@$reserved;
    my $name = refname($ref);
    return if !grep { $_ eq $name } @$reserved;

    fail_with('plugin_ref_reserved', "ref is reserved by the host: $ref",
              { ref => $ref });
}

# PRESENCE decides, not truthiness and not undef. A JSON `null` is a
# present value in JavaScript (`undefined !== null`), so it must be one
# here - which is why this asks `exists` and not `defined`.
sub config_pick {
    my ($src, $key, $dflt) = @_;
    return (ismap($src) && exists $src->{$key}) ? $src->{$key} : $dflt;
}

# ---------------------------------------------------------------------
# resolve_options - section 9.3's ten levels, and 9.4's directives
# ---------------------------------------------------------------------

sub resolve_options {
    my ($input) = @_;
    my $shape = $input->{shape} // {};
    $shape = {} if !ismap($shape);
    check_shape($shape);

    my $ref = canon_ref($input->{ref});
    my $name = refname($ref);
    my $doc = $input->{doc} // {};
    my $profile = $input->{profile};

    my $overlay;
    $overlay = ($doc->{profile} // {})->{$profile} if defined $profile;
    $overlay = {} if !ismap($overlay);

    # ONE ordered merge, lowest to highest. Levels 3-6 are not two
    # namespaces collapsed separately and composed afterwards: that inverts
    # the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION SPECIFICITY, so
    # a prod per-definition default would lose to a base instance value.
    my @layers = (
        config_defaultsof($shape),                        # 1
        $input->{hostdefaults},                           # 2
        config_optsof($doc->{default}, $name),            # 3
        config_optsof($doc->{instance}, $ref),            # 4
        config_optsof($overlay->{default}, $name),        # 5
        config_optsof($overlay->{instance}, $ref),        # 6
        $input->{env},                                    # 7
        $input->{hostoptions},                            # 8
        $input->{loadoptions},                            # 9
        $input->{patch},                                  # 10
    );

    my $out = {};
    for my $layer (@layers) {
        next if !defined $layer;
        $out = config_mergeone($out, $layer, $shape);
    }
    return $out;
}

# The shape's non-directive values are the level-1 defaults.
sub config_defaultsof {
    my ($shape) = @_;
    my %out;
    for my $k (keys %$shape) {
        my $v = $shape->{$k};
        next if ismap($v) && exists $v->{'$MERGE'};
        $out{$k} = $v;
    }
    return \%out;
}

sub config_optsof {
    my ($src, $key) = @_;
    return undef if !defined $src;

    # The array form is equivalent to the map form (section 9.1).
    if (islist($src)) {
        for my $item (@$src) {
            return $item->{options} if canon_ref($item->{ref}) eq $key;
        }
        return undef;
    }

    for my $k (keys %$src) {
        next if canon_ref($k) ne $key;
        my $entry = $src->{$k};
        return ismap($entry) ? $entry->{options} : undef;
    }
    return undef;
}

# Merge ONE layer onto the accumulator, honouring the shape's directives.
# The directive holds at EVERY precedence level, not only between document
# levels - section 9.4 makes it a property of the shape, which does not
# know which layer a value arrived from.
sub config_mergeone {
    my ($base, $over, $shape) = @_;
    return $base if !defined $over;
    return clone_value($over) if !ismap($base) || !ismap($over);

    my %out = %$base;

    for my $k (keys %$over) {
        my $o = $over->{$k};
        my $directive;
        $directive = $shape->{$k}{'$MERGE'}
            if ismap($shape) && ismap($shape->{$k});
        my $b = $out{$k};

        if (defined $directive && !ref $directive && 'replace' eq $directive) {
            $out{$k} = clone_value($o);
        }
        elsif (defined $directive && !ref $directive && 'append' eq $directive) {
            my @bl = islist($b) ? @$b : ();
            my @ol = islist($o) ? @$o : ($o);
            $out{$k} = [ @bl, @ol ];
        }
        elsif (ismap($directive) && exists $directive->{deep}) {
            $out{$k} = config_deepto($b, $o, $directive->{deep});
        }
        else {
            # Library default: deep for maps, REPLACE for lists.
            # struct.merge is element-wise by index, which for option maps
            # is nearly always wrong - ["a"] over ["x","y","z"] yielding
            # ["a","y","z"] is the defect station hit on
            # secrets.providers.
            $out{$k} = (ismap($b) && ismap($o))
                ? config_mergeone($b, $o, undef)
                : clone_value($o);
        }
    }
    return \%out;
}

# Merge N levels below this key, replace below that.
sub config_deepto {
    my ($base, $over, $n) = @_;
    return clone_value($over) if $n <= 0;
    return clone_value($over) if !ismap($base) || !ismap($over);

    my %out = %$base;
    $out{$_} = config_deepto($out{$_}, $over->{$_}, $n - 1) for keys %$over;
    return \%out;
}

# Section 9.4: N is an integer of at least 1, and everything else is an
# error.
#
# `{"deep": 0}` is rejected DESPITE having an obvious reading, because
# "replace at this key" already has a spelling and two spellings for one
# behaviour is the defect class this repo exists to avoid.
sub check_shape {
    my ($shape) = @_;
    return if !ismap($shape);

    for my $k (sortedkeys($shape)) {
        my $v = $shape->{$k};
        next if !ismap($v) || !exists $v->{'$MERGE'};

        my $directive = $v->{'$MERGE'};
        my $type = jsontype($directive);

        if ('str' eq $type) {
            next if grep { $_ eq $directive } @MERGE_WORDS;

            fail_with('plugin_shape_invalid',
                      "invalid \$MERGE directive at $k: $directive",
                      { key => $k, directive => $directive });
        }

        if ('map' eq $type && exists $directive->{deep}) {
            my $n = $directive->{deep};
            # A JSON NUMBER, and an integer of at least 1. Perl would read
            # `"2"` and `!!1` as numbers in a comparison, so the type test
            # comes first - the same hole python guards and ruby does not.
            next if 'num' eq jsontype($n) && $n == int($n) && $n >= 1;

            fail_with('plugin_shape_invalid',
                      "invalid \$MERGE deep at $k: "
                      . Voxgig::Plugin::Types::_json($n),
                      { key => $k, directive => $directive });
        }

        fail_with('plugin_shape_invalid',
                  "invalid \$MERGE directive at $k: "
                  . Voxgig::Plugin::Types::_json($directive),
                  { key => $k, directive => $directive });
    }
}

1;
