# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Ref.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Ref;

# Identity: name+tag, written `name$tag` (section 4).
#
# The four pure functions, and the whole of what `ref` pins. They are the
# first thing a new port implements and the first corpus section it passes.

use strict;
use warnings;
use Voxgig::Plugin::Types qw(fail_with jsontype);

use Exporter 'import';
our @EXPORT_OK = qw(check_name check_tag parse_ref format_ref canon_ref canon refname);

# Section 4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024.
#
# \A and \z, NOT ^ and $. Perl's `$` matches BEFORE A TRAILING NEWLINE, so
# a `^...$` spelling admits "stripe\n" as a name - the same hole the ruby
# port surfaced in python, and the reason four `#trailing-newline` entries
# exist.
our $NAME_RE = qr/\A[a-zA-Z\@][a-zA-Z0-9.~_\-\/]*\z/;

# Section 4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
#
# The asymmetry with a name is deliberate: a tag MAY start with a digit
# because auto-tagging assigns integer tags (`stripe$1`), and a tag admits
# neither `@` nor `/` because a name is a package specifier and a tag is
# not.
our $TAG_RE = qr/\A[a-zA-Z0-9.~_-]+\z/;

our $REF_MAX = 1024;

sub check_name {
    my ($name) = @_;
    return !!0 if 'str' ne jsontype($name);
    return !!0 if '' eq $name || $REF_MAX < length $name;
    return $name =~ $NAME_RE ? !!1 : !!0;
}

sub check_tag {
    my ($tag) = @_;
    return !!0 if 'str' ne jsontype($tag);
    # The empty tag is an ordinary tag (section 4 rule 2). The
    # single-instance case writes no tag and never learns tags exist.
    return !!1 if '' eq $tag;
    return !!0 if $REF_MAX < length $tag;
    return $tag =~ $TAG_RE ? !!1 : !!0;
}

# `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both give
# tag ''.
sub parse_ref {
    my ($str) = @_;
    fail_with('plugin_bad_name', 'ref must be a string')
        if 'str' ne jsontype($str);

    # Split on the FIRST `$`. Nothing in the grammar decides this - `$` is
    # in neither character class - so the corpus is the arbiter (section 4
    # rule 5), and it picks the split that blames the part actually at
    # fault: `a$b$c` is a good name with a bad tag, not the reverse.
    my $cut = index($str, '$');
    my $name = $cut < 0 ? $str : substr($str, 0, $cut);
    my $tag  = $cut < 0 ? ''   : substr($str, $cut + 1);

    fail_with('plugin_bad_name', "invalid plugin name: $name", { name => $name })
        if !check_name($name);
    fail_with('plugin_bad_tag', "invalid plugin tag: $tag",
              { name => $name, tag => $tag })
        if !check_tag($tag);

    return { name => $name, tag => $tag };
}

# The pair -> `name$tag`. An empty tag NEVER writes the separator, which is
# the half of canonicalization format_ref owns: parse tolerates `stripe$`,
# format never produces it, so a round trip is idempotent.
sub format_ref {
    my ($name, $tag) = @_;
    $tag = '' if !defined $tag;
    if (!check_name($name)) {
        my $shown = defined $name && !ref $name ? $name : '(not a name)';
        fail_with('plugin_bad_name', "invalid plugin name: $shown",
                  { name => $name });
    }
    if (!check_tag($tag)) {
        my $shown = defined $tag && !ref $tag ? $tag : '(not a tag)';
        fail_with('plugin_bad_tag', "invalid plugin tag: $shown",
                  { name => $name, tag => $tag });
    }
    return '' eq $tag ? $name : "$name\$$tag";
}

# The canonical spelling of a ref. Section 4 rule 5: ports must
# canonicalize before comparison.
sub canon_ref {
    my ($str) = @_;
    my $r = parse_ref($str);
    return format_ref($r->{name}, $r->{tag});
}

# canon_ref for the internal callers that want the input back unchanged
# when it is not well formed. NEVER use it where a bad ref must be reported
# - the corpus pins plugin_bad_name at every public entry.
sub canon {
    my ($str) = @_;
    my $out = eval { canon_ref($str) };
    return defined $out ? $out : $str;
}

sub refname {
    my ($str) = @_;
    my $out = eval { parse_ref($str)->{name} };
    return defined $out ? $out : $str;
}

1;
