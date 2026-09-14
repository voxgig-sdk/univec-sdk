# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/lib/Voxgig/Sekreto/Addr.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Addr;

# Where an address is judged: is this an http(s) address at all, and may a
# token be sent to it in the clear?
#
# CORE, not a plugin, although only the plugins dial anything. The rule
# that a credential never crosses the network in plaintext is sekreto's
# rather than any one store's, and a custom provider written by a consumer
# gets it for free by calling `checkaddr` - which it can only do if the
# core carries it.
#
# A port of typescript/src/provider/addr.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(checkaddr safeaddr);

# Voxgig::Sekreto uses this module, so a `use` back would be a cycle: the
# failure path is called by name at run time instead.
sub fail { return Voxgig::Sekreto::fail(@_) }

# An address with any userinfo replaced by `[redacted]`, for messages.
#
# Every refusal below names the address it refused, and one of them fires
# precisely because the address carries a credential - so printing it
# verbatim wrote the password to stderr and into the logs. It cannot be
# cleaned up afterwards either: that password was never resolved as a secret,
# so redact() has never seen it and never will. The host is what a reader
# needs to identify which chain entry is at fault; the userinfo is not.
sub safeaddr {
    my ($addr) = @_;

    my $mark = index( $addr, '://' );
    return $addr if -1 == $mark;

    my $rest = substr( $addr, $mark + 3 );
    my ($authority) = $rest =~ m{\A([^/?\#]*)};
    $authority = '' if !defined $authority;

    my $at = rindex( $authority, '@' );
    return $addr if -1 == $at;

    return substr( $addr, 0, $mark + 3 ) . '[redacted]' . substr( $addr, $mark + 3 + $at );
}


# Refuse to send a secret-bearing credential in the clear.
#
# A vault API is HTTPS in any real deployment; plaintext is a dev-mode
# convenience. Sending a token over http to anything but the local machine
# puts both the token and the secret it fetches on the wire for anyone on
# the path, so sekreto will not do it. Loopback stays allowed: that is
# `vault server -dev`, `boru vault serve`, and this repo's own test
# harness.
#
# The address is read by hand, in the same handful of steps in every port,
# rather than by each platform's URL parser. That is deliberate. Twelve
# parsers disagree about malformed input - where userinfo ends, whether
# `0177.0.0.1` is loopback, what an unclosed bracket means - and a check that
# answers differently in different ports is not a check. (Core Perl has no
# URL parser in any case - URI is not core, and this library takes no
# dependencies.)
#
# The rule this parse obeys, and the reason it can be trusted: it is never
# more permissive than the HTTP client that will dial the address. It ends
# the authority at '/', '?' or '#' only, so a client that also breaks on '\'
# (WHATWG does) can only ever see a SHORTER host than this does. It refuses
# userinfo outright rather than locating its end - which also settles a
# disagreement with HTTP::Tiny, whose own parse strips userinfo at the FIRST
# '@' where the RFC says the last. It compares the host literally, so a
# numeric form no parser here agrees on is refused rather than guessed at.
sub checkaddr {
    my ($addr) = @_;

    my $scheme =
          0 == index( $addr, 'https://' ) ? 'https://'
        : 0 == index( $addr, 'http://' )  ? 'http://'
        :                                   '';

    fail( 'sekreto: not an http(s) address: ' . safeaddr($addr) ) if '' eq $scheme;

    my $rest = substr( $addr, length($scheme) );
    my ($authority) = $rest =~ m{\A([^/?\#]*)};
    $authority = '' if !defined $authority;

    # Userinfo is refused outright rather than parsed around, and on https as
    # well as http. No store this library speaks authenticates by userinfo -
    # they take a token or a signature - so an address carrying one is a
    # mistake at best. At worst it is the attack this whole function exists to
    # stop: `http://localhost:8200@evil.example.com/` is a request to
    # evil.example.com that reads, to anything that splits the authority on
    # ':', as loopback.
    fail( 'sekreto: refusing an address with embedded credentials: ' . safeaddr($addr) )
        if -1 != index( $authority, '@' );

    # An opening bracket with no closing one is not an address at all.
    fail( 'sekreto: not a valid http(s) address: ' . safeaddr($addr) )
        if 0 == index( $authority, '[' ) && -1 == index( $authority, ']' );

    return if 'https://' eq $scheme;

    # A bracketed IPv6 literal keeps its brackets. Splitting the authority on
    # the first colon yields '[', so `http://[::1]:8200` could never match -
    # which made the '[::1]' entry below unreachable, and refused a legitimate
    # local vault.
    my $host =
        0 == index( $authority, '[' )
        ? substr( $authority, 0, index( $authority, ']' ) + 1 )
        : ( split( /:/, $authority, 2 ) )[0];
    $host = '' if !defined $host;
    $host = lc $host;

    return if grep { $_ eq $host } ( 'localhost', '127.0.0.1', '::1', '[::1]' );

    fail( 'sekreto: refusing to send a token in plaintext to ' . safeaddr($addr) . ' (use https)' );
}

1;
