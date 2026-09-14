# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Httpjson.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Httpjson;

# The HTTP half of every plugin that speaks to a store over the wire, in
# one place and OUTSIDE the core: a chain of built-ins never loads this
# module. One JSON round-trip, bounded in time and in size, refusing
# redirects and ignoring proxies; and the small helpers every store client
# needs.
#
# A port of typescript/plugins/httpjson.ts, which is canonical.
#
# HTTP::Tiny, JSON::PP and MIME::Base64 are all core Perl, so this port
# stays free of third-party dependencies. HTTPS additionally wants
# IO::Socket::SSL, which HTTP::Tiny picks up when it is present: the TLS
# exception AGENTS.md rule 3 records, and the reason a machine without it
# has a Perl port that cannot reach a real vault.

use strict;
use warnings;

use Exporter 'import';

use HTTP::Tiny   ();
use JSON::PP     ();
use MIME::Base64 ();

our @EXPORT_OK = qw(fetchjson renewafter renewdue stringof unbase64 urlenc);

# Voxgig::Sekreto is loaded by every consumer of this module, and the
# failure path is called by name rather than imported so that nothing here
# has to care which of the two was loaded first.
sub fail { return Voxgig::Sekreto::fail(@_) }

# The string a JSON value reads as, the way the canonical port's String()
# spells it: booleans as words, numbers as themselves, undef stays undef.
sub stringof {
    my ($value) = @_;
    return undef if !defined $value;
    return ( $value ? 'true' : 'false' ) if JSON::PP::is_bool($value);
    return "$value";
}


# RFC 3986 escaping for the URL parts these clients build - a vault name, a
# project, an OAuth form field.
#
# ITS OWN COPY, not the SigV4 canonical form's `uriescape`, though the two
# bodies are the same. They are two contracts: this one escapes a component
# of an address, and that one is part of a signature the spec pins byte for
# byte. Sharing them made every store client - Doppler, Infisical, 1Password
# - load AWS request signing and a hash function to escape a URL, which is a
# small echo of exactly what the core/plugin split was for.
sub urlenc {
    my ($text) = @_;
    utf8::encode($text) if utf8::is_utf8($text);
    $text =~ s/([^A-Za-z0-9\-._~])/sprintf( '%%%02X', ord($1) )/ge;
    return $text;
}


# Decode standard base64, or undef when the text is not base64.
#
# MIME::Base64::decode_base64 SKIPS characters outside the alphabet, so a
# corrupted payload decoded to plausible-looking bytes that the caller then
# returned AS THE SECRET. The alphabet is checked first, so a store that
# answered incoherently can be told apart from one that answered.
sub unbase64 {
    my ($text) = @_;

    ( my $trimmed = $text ) =~ s/\s+//g;

    return undef if $trimmed !~ m{\A[A-Za-z0-9+/]*={0,2}\z};
    return undef if 0 != length($trimmed) % 4;

    return MIME::Base64::decode_base64($trimmed);
}


# One JSON round-trip, returning (status, decoded-json-or-undef). A 404 is
# a normal answer here, not a failure: it means the store has no such
# secret. Network failure is always an error - an unreachable store is a
# store that could not answer.
sub fetchjson {
    my ( $method, $url, $headers, $body ) = @_;

    my $options = { headers => $headers || {} };
    $options->{content} = $body if defined $body;

    # A secrets client dials the address it was configured with and nowhere
    # else. HTTP::Tiny's constructor calls _set_proxies, which reads
    # http_proxy WITHOUT exempting loopback - so with that variable set,
    # `X-Vault-Token` for a local dev vault went, in the clear, to whatever
    # it named. checkaddr permits plaintext to loopback precisely because
    # nothing leaves the machine; an environment variable it cannot see must
    # not be able to make that false. All three keys are needed: an explicit
    # undef is what suppresses the lookup.
    # max_size is the response-body bound every port carries. HTTP::Tiny
    # accepts it and this port was not passing it, so an endless body was
    # accumulated in memory until the deadline - which on a loopback or
    # datacentre link is gigabytes. Far above anything real: the largest
    # legitimate payload here is Doppler's whole-config download, measured
    # in kilobytes.
    my $response = HTTP::Tiny->new(
        timeout      => 10,
        verify_SSL   => 1,
        max_redirect => 0,
        max_size     => 8 * 1024 * 1024,
        proxy        => undef,
        http_proxy   => undef,
        https_proxy  => undef,
    )->request( $method, $url, $options );

    # HTTP::Tiny reports an over-size body as a 599 with this text. An
    # endless body is a store that could not answer, so it must raise
    # rather than become a miss - the latter would fall through to a
    # weaker store on an attacker's cue.
    if ( 599 == $response->{status}
        && -1 != index( $response->{content} || '', 'Size of response body exceeds' ) )
    {
        ( my $plain = $url ) =~ s/\?.*//s;
        fail( 'sekreto: oversized response from ' . $plain );
    }

    # HTTP::Tiny reports transport failures as a synthetic 599.
    if ( 599 == $response->{status} ) {
        ( my $plain = $url ) =~ s/\?.*//s;
        fail( 'sekreto: cannot reach ' . $plain . ': ' . ( $response->{content} || '' ) );
    }

    my $parsed = eval { JSON::PP->new->decode( $response->{content} ) };

    # A success status promised JSON; a body that does not parse means
    # the store could not answer coherently, and treating it as a miss
    # would fall through to a weaker store. Error statuses may carry
    # any body - they are decided on status alone.
    if ( $@ && 200 == $response->{status} ) {
        ( my $plain = $url ) =~ s/\?.*//s;
        fail( 'sekreto: malformed response from ' . $plain );
    }

    return ( $response->{status}, $parsed );
}



# When a logged-in token must be renewed: shortly before its lease runs
# out, now + max(seconds - 60, 1). A missing or non-positive expiry means
# "never renew" - undef here, the canonical port's Infinity.
sub renewafter {
    my ($seconds) = @_;

    no warnings 'numeric';
    my $lease = ( defined $seconds && !ref($seconds) ) ? 0 + $seconds : 0;

    return undef if !( 0 < $lease );

    my $delta = $lease - 60;
    $delta = 1 if 1 > $delta;

    return time() + $delta;
}


# Is this token due for renewal? A configured token (renewat undef) never
# is.
sub renewdue {
    my ($renewat) = @_;
    return defined $renewat && time() >= $renewat ? 1 : 0;
}

1;
