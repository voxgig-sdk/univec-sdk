# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Secretspec.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Secretspec;

# The secretspec plugin: SecretSpec (https://secretspec.dev) through its
# CLI.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# A port of typescript/plugins/secretspec.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Plugins::Proc ();

our @EXPORT_OK = qw(secretspec);

# Does this SecretSpec failure mean "no such secret" rather than "I could
# not answer"?
#
# SecretSpec says `Secret 'API_TOKEN' not found` for both a name it does not
# declare and one declared with no value, and both are misses: this store
# does not hold it, so the chain carries on.
#
# MATCHED ON THE WHOLE PHRASE, NOT ON "not found". SecretSpec also says
# `Provider backend 'keyring' not found`, which is a store that could not
# answer at all - and reading that as a miss is the worst failure this
# library has, because the chain then falls through to a weaker store
# without saying so. The key is required to appear, so the two cannot be
# confused.
sub secretspecmiss {
    my ( $why, $key ) = @_;
    return index( $why, "Secret '" . $key . "' not found" ) >= 0 ? 1 : 0;
}

# SecretSpec (https://secretspec.dev).
#
# SecretSpec is a declaration - a `secretspec.toml` naming the secrets a
# project needs - plus a chain of its own backends to satisfy them from.
# That makes it the same shape as sekreto one level down, and the reason to
# support it is the same reason sekreto exists: a project that has already
# declared its secrets there should not have to declare them again here.
#
# Read through its CLI, as boru is, because that is the interface it offers
# a program in another language: `secretspec get API_TOKEN` prints the value
# on stdout and nothing else. A sekreto name maps to a SecretSpec key
# exactly as it maps to an environment variable - `api.token` is
# `API_TOKEN` - which is the convention SecretSpec's own examples use.
#
# `backend` selects one of SecretSpec's backends (`--provider`, e.g.
# `keyring` or `dotenv://.env`) and is called `backend` here only because
# `provider` already means something else in this library.
#
# A reason is required, not optional: SecretSpec records every read in an
# audit log and refuses to read at all without one. sekreto sends `sekreto`
# unless told otherwise, so the audit trail says which tool asked.
{

    package Voxgig::Sekreto::Plugins::Secretspec::Provider;

    sub new {
        my ( $class, $command, $file, $profile, $backend, $reason, $prefix ) = @_;
        return bless {
            command => $command || 'secretspec',
            file    => $file,
            profile => $profile,
            backend => $backend,
            reason  => $reason,
            prefix  => $prefix,
        }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;

        my $key = Voxgig::Sekreto::envkey( $name, $self->{prefix} );

        my @args;
        push @args, '--file', $self->{file} if $self->{file};
        push @args, 'get', $key;
        push @args, '--provider', $self->{backend} if $self->{backend};
        push @args, '--profile', $self->{profile} if $self->{profile};
        push @args, '--reason', ( $self->{reason} || 'sekreto' );

        my ( $out, $err, $status ) =
          Voxgig::Sekreto::Plugins::Proc::runcmd( $self->{command}, @args );

        if ( 0 == $status ) {
            # The value and one newline, and nothing else.
            $out =~ s/\n\z//;
            return $out;
        }

        $err =~ s/^\s+|\s+$//g;

        return undef if Voxgig::Sekreto::Plugins::Secretspec::secretspecmiss( $err, $key );

        Voxgig::Sekreto::fail(
            'sekreto: secretspec error: ' . ( '' eq $err ? 'exit ' . $status : $err ) );
    }

    sub describe {
        my ($self) = @_;
        return 'secretspec' . ( $self->{backend} ? ':' . $self->{backend} : '' );
    }
}


# The plugin: the `secretspec` provider kind, as a voxgig/plugin
# definition.
sub secretspec {
    return providerplugin(
        'secretspec',
        sub {
            my ($spec) = @_;
            return Voxgig::Sekreto::Plugins::Secretspec::Provider->new(
                $spec->{command}, $spec->{file},   $spec->{profile},
                $spec->{backend}, $spec->{reason}, $spec->{prefix}
            );
        }
    );
}

1;
