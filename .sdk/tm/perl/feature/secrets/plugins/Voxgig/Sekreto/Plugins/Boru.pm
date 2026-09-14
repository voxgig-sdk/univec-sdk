# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Boru.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Boru;

# The boru plugin: a boru vault through its CLI, or over `boru vault serve`.
# Needs a child process, or HTTPS in wire mode.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# A port of typescript/plugins/boru.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Addr ();
use Voxgig::Sekreto::Plugins::Httpjson ();
use Voxgig::Sekreto::Plugins::Proc ();

our @EXPORT_OK = qw(boru);

# A boru vault (https://github.com/boru-lang/boru), read through the boru
# CLI: `boru vault get --reveal <alias>` prints the secret on stdout, and
# nothing else.
#
# A sekreto name is already a valid boru alias, so `api.token` crosses over
# unchanged. A `namespace` qualifies it the way boru writes it,
# `<namespace>:<name>`.
#
# The passphrase is read by boru itself from `BORU_VAULT_PASSPHRASE`. sekreto
# never accepts it as config and never puts it on a command line, where it
# would show up in the process table.
#
# boru's `vault proxy` and `vault mcp` remain out of bounds: they are a
# credential *broker*, built precisely so the caller never receives the
# credential. The wire route in is `vault serve` - the provider below.
{

    package Voxgig::Sekreto::Plugins::Boru::Cli;

    sub new {
        my ( $class, $command, $namespace, $home ) = @_;
        return bless {
            command   => $command || 'boru',
            namespace => $namespace,
            home      => $home,
        }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;

        Voxgig::Sekreto::checkname($name);

        my $alias = $self->{namespace} ? $self->{namespace} . ':' . $name : $name;

        # BORU_HOME is set for the child only, then restored.
        local $ENV{BORU_HOME} = $self->{home} if $self->{home};

        my ( $out, $err, $status ) = Voxgig::Sekreto::Plugins::Proc::runcmd(
            $self->{command}, 'vault', 'get', '--reveal', $alias );

        if ( 0 == $status ) {
            # boru prints the value and one newline, and nothing else.
            $out =~ s/\n\z//;
            return $out;
        }

        $err =~ s/^\s+|\s+$//g;

        # "no alias named" is boru saying it does not hold this secret, which
        # is a miss: the chain carries on to the next provider. A locked vault
        # or a wrong passphrase is not a miss - treating it as one would fall
        # through to a weaker store without saying so.
        return undef if Voxgig::Sekreto::Plugins::Boru::borumiss($err);

        Voxgig::Sekreto::fail(
            'sekreto: boru vault error: ' . ( '' eq $err ? 'exit ' . $status : $err ) );
    }

    sub describe {
        my ($self) = @_;
        return 'boru' . ( $self->{namespace} ? ':' . $self->{namespace} : '' );
    }
}

# The same boru vault over its wire protocol: `boru vault serve` publishes
# a read-only, HashiCorp-shaped provision API (boru's
# design/VAULT-WIRE-PROTOCOL.0.md), authenticated by a capability token
# from `boru vault grant`.
#
# A sekreto name is already a valid boru alias, and boru aliases keep
# their dots, so `api.token` is the single path segment `api.token` - not
# the `api`/`token` split a HashiCorp KV gets. The value is the `value`
# field. A 404 is a miss; anything else the server refuses (a revoked
# capability, a sealed vault) is an error.
{

    package Voxgig::Sekreto::Plugins::Boru::Wire;

    sub new {
        my ( $class, $addr, $token, $namespace, $mount ) = @_;

        ( my $useaddr = defined $addr ? $addr : '' ) =~ s{/$}{};

        return bless {
            addr      => $useaddr,
            token     => defined $token ? $token : '',
            namespace => $namespace,
            mount     => $mount || 'secret',
        }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;

        Voxgig::Sekreto::checkname($name);
        Voxgig::Sekreto::Addr::checkaddr( $self->{addr} );

        my $alias = $self->{namespace} ? $self->{namespace} . '/' . $name : $name;
        my $url   = $self->{addr} . '/v1/' . $self->{mount} . '/data/' . $alias;

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET', $url,
            { 'X-Vault-Token' => $self->{token} } );

        return undef if 404 == $status;

        Voxgig::Sekreto::fail(
            'sekreto: boru serve error: ' . $status . ': ' . $url )
          if 200 != $status;

        my $data =
          ( 'HASH' eq ref( $body || '' ) && 'HASH' eq ref( $body->{data} || '' ) )
          ? $body->{data}{data}
          : undef;

        my $value = 'HASH' eq ref( $data || '' ) ? $data->{value} : undef;
        return Voxgig::Sekreto::Plugins::Httpjson::stringof($value);
    }

    sub describe {
        my ($self) = @_;
        return 'boru:' . $self->{addr};
    }
}
# Does this boru failure mean "no such secret" rather than "I could not
# answer"? Matched on boru's own wording for a missing alias.
sub borumiss {
    my ($why) = @_;
    return index( $why, 'no alias named' ) >= 0 ? 1 : 0;
}


# The plugin: the `boru` provider kind, as a voxgig/plugin definition.
#
# One kind, two ways in: an `addr` is the wire protocol, and its absence is
# the CLI. The choice is made here, once, where the spec is read.
sub boru {
    return providerplugin(
        'boru',
        sub {
            my ($spec) = @_;

            return Voxgig::Sekreto::Plugins::Boru::Wire->new( $spec->{addr},
                $spec->{token}, $spec->{namespace}, $spec->{mount} )
              if $spec->{addr};

            return Voxgig::Sekreto::Plugins::Boru::Cli->new( $spec->{command},
                $spec->{namespace}, $spec->{home} );
        }
    );
}

1;
