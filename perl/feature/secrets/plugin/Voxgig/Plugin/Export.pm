# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Export.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Export;

# Exports (section 11).
#
# An instance publishes values for other plugins and for the application.
# Read with `host->exports('retry$fast/client')`.
#
# THE UNQUALIFIED ALIAS IS THE INTERESTING PART. `retry/client` resolves to
# the UNTAGGED instance if one exists; if not, and exactly one tagged
# instance exports that key, it resolves to that one; if two do, it is
# `plugin_export_ambiguous` - deliberately diverging from seneca's silent
# last-wins, because with multi-instance as a headline feature an ambiguous
# alias is a defect waiting for production.

use strict;
use warnings;
use Voxgig::Plugin::Types qw(fail_with sortstrings);
use Voxgig::Plugin::Ref qw(canon parse_ref refname);

use Exporter 'import';
our @EXPORT_OK = qw(resolve_export);

sub resolve_export {
    my ($spec, $exported) = @_;
    my $cut = index($spec, '/');
    fail_with('plugin_export_ambiguous', "export spec needs a key: $spec",
              { spec => $spec })
        if $cut < 0;
    my $head = substr($spec, 0, $cut);
    my $key  = substr($spec, $cut + 1);

    # A fully qualified ref: exactly one answer or none.
    my $want = canon($head);
    for my $e (@$exported) {
        return $e->{value} if $e->{ref} eq $want && $e->{key} eq $key;
    }

    # An alias: the name, not a ref. Look at every instance of it.
    my @byname = grep { refname($_->{ref}) eq $head && $_->{key} eq $key }
        @$exported;
    return undef if !@byname;

    for my $e (@byname) {
        return $e->{value} if '' eq parse_ref($e->{ref})->{tag};
    }

    return $byname[0]{value} if 1 == @byname;

    my @refs = sortstrings(map { $_->{ref} } @byname);
    fail_with('plugin_export_ambiguous',
              "alias $spec matches " . scalar(@refs) . ' instances: '
              . join(', ', @refs),
              { spec => $spec, refs => \@refs });
}

1;
