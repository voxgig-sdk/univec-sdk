# VENDORED: @voxgig/plugin sdk-20260908-1556-0 (perl/lib/Voxgig/Plugin/Resolve.pm)
# Source: https://github.com/voxgig/plugin @ 91c4936555a4ce198669ca2c578b91e27e92e5ec  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Plugin::Resolve;

# Dynamic resolution (section 10.2) - name to candidate module ids.
#
# PURE. It returns the ids a host WOULD try, in order; it does not load
# anything. That separation is what lets the corpus pin resolution in every
# language including those with no dynamic loading at all, and it is why
# section 15.4 puts real module loading in per-port integration tests
# rather than here.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(resolve_candidates resolve_from);

our @DEFAULT_SOURCES = (
    { kind => 'module',
      prefix => [ '@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', '' ] },
);

sub resolve_candidates {
    my ($name, $sources) = @_;
    my @out;
    my %seen;

    # A SCOPED NAME RESOLVES VERBATIM ONLY (section 10.2). `@acme/thing` is
    # already a package id; prefixing it produces
    # `@voxgig/plugin-@acme/thing`, which is not a thing that can exist.
    return [$name] if 0 == index($name, '@');

    my $list = (!defined $sources || 0 == @$sources)
        ? \@DEFAULT_SOURCES : $sources;

    for my $src (@$list) {
        my $kind = $src->{kind} // '';
        if ('module' eq $kind) {
            my $prefixes = $src->{prefix};
            $prefixes = [''] if !defined $prefixes || 0 == @$prefixes;
            for my $p (@$prefixes) {
                my $id = $p . $name;
                next if $seen{$id}++;
                push @out, $id;
            }
        }
        elsif ('path' eq $kind) {
            my $dir = $src->{dir} // '';
            $dir =~ s{/+\z}{};
            my $id = "$dir/$name";
            next if $seen{$id}++;
            push @out, $id;
        }
    }

    return \@out;
}

# A MODULE PATH IS NOT A NAME (section 10.2). The ref grammar starts a name
# with a letter or `@`, so `./local/thing` is not a ref and never reaches
# candidate generation - seneca allows a path where a plugin name goes, and
# this design deliberately does not, because a ref is an ADDRESS WITHIN A
# HOST and a path is a LOCATION ON A DISK.
sub resolve_from {
    my ($from) = @_;
    return [$from];
}

1;
