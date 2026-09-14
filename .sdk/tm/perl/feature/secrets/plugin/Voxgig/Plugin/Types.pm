# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Types.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Types;

# Shared types. Deliberately small: the design's section 19 budget says
# the library owns naming, configuration, lifecycle, ordering, binding and
# teardown, and nothing else.
#
# PERL'S ONE STRUCTURAL HAZARD IS THAT IT HAS NO JSON TYPES. A scalar that
# holds 1 and a scalar that holds "1" are the same thing to `==` and to
# `eq`, and the corpus pins them as DIFFERENT (capability/match). So this
# file carries `jsontype`, which reads the SV's own flags - the same test
# JSON::PP uses to decide whether to emit a number - and every comparison
# in the port goes through it.
#
# The second hazard is that a hash has NO ORDER, and a randomized one at
# that. Every place the canonical iterates a map, this port sorts the keys
# first; `sortstrings` is the one spelling of that.

use strict;
use warnings;
use B ();
use Scalar::Util qw(blessed reftype);

# PERL 5.36 OR LATER, SAID ONCE, HERE.
#
# `builtin` is core from 5.36 and does not exist before it, so on 5.34 the
# interpreter reports `Can't locate builtin.pm` and then unwinds through a
# BEGIN failure for every module on the way down — eight of them when the
# library is loaded through a host — naming each file and never the
# requirement. The README states the minimum; nothing in the code did, so
# the one person who most needs to be told reads the least useful message.
#
# This is the file that depends on it: `is_bool` is the only way perl can
# tell a true boolean from the number 1, and `jsontype` below is the whole
# of the port's answer to having no JSON types.
#
# A BEGIN block rather than `use v5.36`, which would also switch on that
# release's feature bundle and change how the rest of this file compiles.
BEGIN {
    if ($] < 5.036) {
        die "Voxgig::Plugin::Types requires perl 5.36 or later (this is $]):"
            . " it uses builtin::is_bool, the only way perl can tell a true"
            . " boolean from the number 1.\n";
    }
}

use builtin qw(is_bool);
no warnings 'experimental::builtin';

use Exporter 'import';
our @EXPORT_OK = qw(
    fail_with codeof formaterror jsontype truthy ismap islist
    sortstrings sortedkeys stable_sort_by clone_value
    STATUSES DETAIL_ORDER
);

# Section 5.1's seven statuses, and no more. A port that adds an eighth is
# diverging. `loading` and `closing` are observable only from inside a
# callback or from another thread.
our @STATUSES = qw(declared loaded pending live failed loading closing);

# Section 12's detail fields, IN THIS FIXED ORDER.
#
# The order is part of the contract, not a formatting preference. An
# earlier draft named six fields while other sections promised diagnostics
# that had nowhere to go, which would have left each port inventing its own
# order and breaking message parity.
our @DETAIL_ORDER = qw(
    host ref name tag point key capability
    range version match candidates cycle holders
    refs path cause
);

# The JSON type of a value, read from the scalar itself.
#
# `is_bool` is 5.36's, and it is the only reason this port can tell `true`
# from `1` at all - perl's own booleans ARE 1 and "", and nothing else in
# the language distinguishes them. The corpus runner converts JSON::PP's
# blessed booleans to native ones on the way in, so both spellings answer
# 'bool' here.
#
# THE NUMBER TEST HAS A KNOWN LIMIT, and it is perl's rather than this
# port's: using a numeric scalar in STRING context sets its POK flag
# permanently, after which it reads as a string. JSON::PP's encoder has
# exactly the same limit for exactly the same reason. Nothing in this port
# interpolates a corpus value before comparing it, and `same` would report
# a loud disagreement rather than a quiet pass if something ever did.
sub jsontype {
    my ($v) = @_;
    return 'null' if !defined $v;
    my $r = ref $v;
    if ($r) {
        return 'list' if 'ARRAY' eq $r;
        return 'map'  if 'HASH' eq $r;
        return 'bool' if 'JSON::PP::Boolean' eq $r;
        return 'code' if 'CODE' eq $r;
        return 'object';
    }
    return 'bool' if is_bool($v);
    my $flags = B::svref_2object(\$v)->FLAGS;
    return 'num'
        if ($flags & (B::SVp_IOK() | B::SVp_NOK()))
        && !($flags & B::SVp_POK());
    return 'str';
}

sub ismap  { 'HASH' eq (ref($_[0]) // '') }
sub islist { 'ARRAY' eq (ref($_[0]) // '') }

# Ruby's truthiness, which is not perl's: `0`, `""` and an empty list are
# all values the corpus distinguishes from absence. A transcribed
# truthiness test says what it means here - present, and not false.
sub truthy {
    my ($v) = @_;
    return 0 if !defined $v;
    return $v ? 1 : 0 if 'bool' eq jsontype($v);
    return 1;
}

# Byte-wise. `sort` with no comparator is already `cmp`, but saying it
# leaves no doubt that this is not a locale or a numeric sort.
sub sortstrings { return sort { $a cmp $b } @_ }

sub sortedkeys { my ($h) = @_; return sort { $a cmp $b } keys %$h }

# STABLE sort by a computed key list. `use sort 'stable'` is on in every
# file that sorts, so this is a comparator rather than a decoration - but
# the COMPARISON is still the port's own, because the canonical's rank
# falls through tiers of mixed numbers and strings.
sub stable_sort_by {
    my ($list, $keyof) = @_;
    my @out = sort { cmpkey($keyof->($a), $keyof->($b)) } @$list;
    return \@out;
}

# Compare two key lists part by part. Numbers compare numerically, strings
# byte-wise, and a nested list recurses - which is what the capability rank
# needs for its version triple.
sub cmpkey {
    # NOT `my ($a, $b)`: `$a` and `$b` are the sort globals, and shadowing
    # them inside a routine a sort block calls is the classic way to make a
    # comparator quietly compare nothing.
    my ($ka, $kb) = @_;
    my $n = @$ka > @$kb ? scalar @$ka : scalar @$kb;
    for my $i (0 .. $n - 1) {
        my $x = $i < @$ka ? $ka->[$i] : 0;
        my $y = $i < @$kb ? $kb->[$i] : 0;
        my $c;
        if (islist($x) && islist($y)) {
            $c = cmpkey($x, $y);
        }
        elsif ('str' eq jsontype($x) || 'str' eq jsontype($y)) {
            $c = "$x" cmp "$y";
        }
        else {
            $c = ($x // 0) <=> ($y // 0);
        }
        return $c if 0 != $c;
    }
    return 0;
}

sub clone_value {
    my ($v) = @_;
    return [ map { clone_value($_) } @$v ] if islist($v);
    return { map { $_ => clone_value($v->{$_}) } keys %$v } if ismap($v);
    return $v;
}

# `plugin/<code>: <text> [<key>=<value> ...]`
#
# Values render as COMPACT JSON, so a value containing a space or a bracket
# cannot break the parse, and a list renders as a JSON array. The bracket
# is absent entirely when no field applies.
sub formaterror {
    my ($code, $text, $details) = @_;
    $details //= {};
    my @parts;
    for my $k (@DETAIL_ORDER) {
        next if !exists $details->{$k};
        push @parts, $k . '=' . _json($details->{$k});
    }
    my $tail = @parts ? ' [' . join(' ', @parts) . ']' : '';
    return "plugin/$code: $text$tail";
}

# A local encoder rather than JSON::PP, because the library must not
# depend on a module the port could be embedded without - and because the
# only values it ever sees are error details.
sub _json {
    my ($v) = @_;
    my $type = jsontype($v);
    return 'null' if 'null' eq $type;
    return $v ? 'true' : 'false' if 'bool' eq $type;
    return "$v" if 'num' eq $type;
    if ('list' eq $type) {
        return '[' . join(',', map { _json($_) } @$v) . ']';
    }
    if ('map' eq $type) {
        return '{' . join(',',
            map { _json("$_") . ':' . _json($v->{$_}) } sortedkeys($v)) . '}';
    }
    my $s = "$v";
    $s =~ s/(["\\])/\\$1/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\x08/\\b/g;
    $s =~ s/\x0c/\\f/g;
    # THE WHOLE CONTROL RANGE, not the five spellings with a short escape.
    # A cause or detail carrying \x01 - which a foreign library's message
    # can - emitted the raw byte inside quotes, and the message stopped
    # being the parseable JSON section 12 pins it as.
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return '"' . $s . '"';
}

# Every error carries a section 12 code. Ports compare by CODE and never by
# message: wording is a port's own business, and pinning the words would
# make every translation a corpus change. The FORMAT, however, is pinned -
# a parseable message is what makes a log searchable across twenty
# languages.
{
    package Voxgig::Plugin::Error;

    use overload '""' => sub { $_[0]->{message} }, fallback => 1;

    sub new {
        my ($class, $code, $text, $details) = @_;
        return bless {
            code    => $code,
            text    => $text,
            details => $details // {},
            message => Voxgig::Plugin::Types::formaterror($code, $text, $details),
        }, $class;
    }

    sub code    { $_[0]->{code} }
    sub message { $_[0]->{message} }
}

sub fail_with {
    my ($code, $text, $details) = @_;
    die Voxgig::Plugin::Error->new($code, $text, $details);
}

# The section 12 code of an error, or '' for one this library did not
# raise. The corpus compares by code, so the driver needs one place that
# knows how to read it.
#
# A DUCK-TYPED READ, not an isa check: section 12 identifies an error by
# its code and not by its class, and a plugin raising its own coded object
# keeps that code (Host::run reads this to decide whether to wrap).
sub codeof {
    my ($err) = @_;
    return '' if !defined $err || !ref $err;

    # `ref` ON A BLESSED REFERENCE RETURNS THE CLASS NAME, NOT 'HASH', so
    # gating on `'HASH' eq ref` read only unblessed hashes and this
    # library's own class - an isa check wearing a duck's hat, and the
    # opposite of what the comment above claims. A plugin raising its own
    # coded object had the code dropped and `Host::run` rewrote it to
    # `plugin_<phase>_failed`. `reftype` is the flag `ref` masks.
    my $code;
    if (blessed($err) && $err->can('code')) {
        $code = eval { $err->code };
    } elsif ('HASH' eq (reftype($err) // '')) {
        $code = $err->{code};
    }
    return defined $code && !ref $code ? "$code" : '';
}

1;
