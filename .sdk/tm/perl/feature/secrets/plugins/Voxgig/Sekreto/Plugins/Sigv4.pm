# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Sigv4.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Sigv4;

# AWS Signature Version 4, hand-rolled.
#
# UNDER plugins/, WITH THE AWS PLUGIN, and not in the core: this is the
# sharpest instance of the line the split draws, because signing is the one
# thing here that needs a hash function, and the core of no port imports
# one. Only `awssecrets` and `awsparams` use it
# (docs/design/plugin-providers.md).
#
# The AWS providers need exactly one thing from the AWS SDK - request
# signing - and taking the SDK for it would break the no-dependency rule
# that keeps ten ports honest. SigV4 is a stable, published algorithm
# built from HMAC-SHA256, which Digest::SHA (core Perl) already has.
#
# `sigv4` is pure: the caller passes the timestamp, so the same input
# yields the same signature everywhere. That is what lets the shared spec
# carry known-answer cases that all ten ports must reproduce bit-for-bit,
# and lets the integration mock recompute the signature server-side.
#
# A port of typescript/plugins/sigv4.ts, which is canonical.

use strict;
use warnings;

use Digest::SHA ();

use Exporter 'import';

our @EXPORT_OK = qw(sigv4 uriescape);

sub sha256hex {
    my ($text) = @_;
    utf8::encode($text) if utf8::is_utf8($text);
    return Digest::SHA::sha256_hex($text);
}

# Digest::SHA takes (data, key); the callers here say (key, data), the
# way every SigV4 description writes the key chain, so the flip is done
# once, in one place.
sub hmac {
    my ( $key, $text ) = @_;
    utf8::encode($text) if utf8::is_utf8($text);
    return Digest::SHA::hmac_sha256( $text, $key );
}

sub hmachex {
    my ( $key, $text ) = @_;
    utf8::encode($text) if utf8::is_utf8($text);
    return Digest::SHA::hmac_sha256_hex( $text, $key );
}

# RFC 3986 escaping, which is stricter than most languages' default
# URL-encoding: uppercase hex, and everything outside the unreserved
# characters (ALPHA / DIGIT / '-' / '.' / '_' / '~') is escaped - AWS
# wants `!`, `'`, `(`, `)` and `*` escaped too.
#
# Httpjson's `urlenc` has the same body and is deliberately not this
# function: this one is part of a signature the spec pins, and depending on
# it made every store client load a hash function to escape a URL.
sub uriescape {
    my ($text) = @_;
    utf8::encode($text) if utf8::is_utf8($text);
    $text =~ s/([^A-Za-z0-9\-._~])/sprintf( '%%%02X', ord($1) )/ge;
    return $text;
}

# Undo percent-encoding, byte by byte.
sub uridecode {
    my ($text) = @_;
    $text =~ s/%([0-9A-Fa-f]{2})/chr( hex($1) )/ge;
    return $text;
}

# The canonical query string: each pair RFC 3986-escaped, sorted by
# escaped key then escaped value.
sub canonicalquery {
    my ($query) = @_;

    return '' if '' eq $query;

    my @pairs;
    for my $pair ( split( /&/, $query, -1 ) ) {
        my $eq    = index( $pair, '=' );
        my $key   = -1 == $eq ? $pair : substr( $pair, 0, $eq );
        my $value = -1 == $eq ? ''    : substr( $pair, $eq + 1 );
        push @pairs, [ uriescape( uridecode($key) ), uriescape( uridecode($value) ) ];
    }

    @pairs = sort { $a->[0] cmp $b->[0] || $a->[1] cmp $b->[1] } @pairs;

    return join( '&', map { $_->[0] . '=' . $_->[1] } @pairs );
}

# Pull the host (with any port), path and query out of a URL, the way a
# WHATWG URL object presents them: the scheme's default port is dropped
# from the host, and an empty path reads as `/`.
sub parseurl {
    my ($url) = @_;

    my ( $scheme, $host, $path, $query ) =
      ( defined $url ? $url : '' ) =~ m{^(https?)://([^/?#]+)([^?#]*)(?:\?([^#]*))?};

    die 'sekreto: sigv4: not a parseable url: ' . ( defined $url ? $url : '' ) . "\n"
      if !defined $host;

    $host =~ s/:443$// if 'https' eq $scheme;
    $host =~ s/:80$//  if 'http' eq $scheme;

    return (
        $host,
        ( defined $path && '' ne $path ) ? $path : '/',
        defined $query ? $query : '',
    );
}

# Sign one request. Returns (a map of) the headers to attach:
# authorization, x-amz-date, and x-amz-security-token when a session
# token was given.
sub sigv4 {
    my ($input) = @_;

    my ( $host, $path, $query ) = parseurl( $input->{url} );

    my $datetime = $input->{datetime};
    my $date     = substr( $datetime, 0, 8 );
    my $body     = defined $input->{body} ? $input->{body} : '';

    # Every header that will be signed: the caller's extras, plus host and
    # x-amz-date (and the session token when present), lower-cased and
    # trimmed the way the canonical form requires.
    # Canonical header values are trimmed AND internally collapsed -
    # AWS folds sequential whitespace to one space before signing, so a
    # header like "a  b" must sign as "a b" or the service refuses it.
    my %headers;
    my $extra = $input->{headers} || {};
    for my $key ( keys %$extra ) {
        my $value = defined $extra->{$key} ? "$extra->{$key}" : '';
        $value =~ s/^\s+|\s+$//g;
        $value =~ s/\s+/ /g;
        $headers{ lc($key) } = $value;
    }
    $headers{host}                   = $host;
    $headers{'x-amz-date'}           = $datetime;
    $headers{'x-amz-security-token'} = $input->{session} if $input->{session};

    my @names            = sort keys %headers;
    my $canonicalheaders = join( '', map { $_ . ':' . $headers{$_} . "\n" } @names );
    my $signedheaders    = join( ';', @names );

    my $canonicalrequest = join( "\n",
        uc( $input->{method} ),
        $path,
        canonicalquery($query),
        $canonicalheaders,
        $signedheaders,
        sha256hex($body),
    );

    my $scope = $date . '/' . $input->{region} . '/' . $input->{service} . '/aws4_request';

    my $stringtosign =
      join( "\n", 'AWS4-HMAC-SHA256', $datetime, $scope, sha256hex($canonicalrequest) );

    my $kdate     = hmac( 'AWS4' . $input->{secret}, $date );
    my $kregion   = hmac( $kdate,                    $input->{region} );
    my $kservice  = hmac( $kregion,                  $input->{service} );
    my $ksigning  = hmac( $kservice,                 'aws4_request' );
    my $signature = hmachex( $ksigning, $stringtosign );

    my %out = (
        authorization => 'AWS4-HMAC-SHA256 Credential='
          . $input->{keyid} . '/'
          . $scope
          . ', SignedHeaders='
          . $signedheaders
          . ', Signature='
          . $signature,
        'x-amz-date' => $datetime,
    );

    $out{'x-amz-security-token'} = $input->{session} if $input->{session};

    return \%out;
}

1;
