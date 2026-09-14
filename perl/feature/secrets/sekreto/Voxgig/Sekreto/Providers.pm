# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/lib/Voxgig/Sekreto/Providers.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Providers;

# What a provider is, how a provider kind becomes a voxgig/plugin
# definition - and the four BUILT-IN kinds.
#
# A provider answers one question: "do you have this secret?" It returns the
# value, or undef to mean "ask the next one". Nothing else about a provider
# is visible to the caller - which is the point: an app reads `api.token`
# and never learns whether it came from the environment, a .env file,
# HashiCorp Vault, AWS, GCP, Azure or a boru vault.
#
# Two failure shapes, and they are never interchangeable. A store that does
# not hold the secret is a MISS (undef) - the chain carries on. A store that
# could not answer - bad credentials, unreachable host, missing
# configuration - is an ERROR: falling through there would quietly reach
# for a weaker store.
#
# THIS MODULE LOADS NO HTTP::Tiny, NO Digest::SHA AND NO IPC::Open3. What
# makes a kind built in is that it needs nothing of the platform beyond
# reading a local file; every kind that opens a socket, signs a request or
# spawns a process is a plugin under `plugins/`, its own module, loaded
# only by a program that names it - see docs/design/plugin-providers.md.
#
# A provider is duck-typed, as everything else in this port is: any object
# with `lookup` and `describe` will do, and `providerplugin` turns one into
# a provider KIND the chain can name.
#
# A port of typescript/src/provider/support.ts and
# typescript/src/provider/builtin.ts, which are canonical.

use strict;
use warnings;

use Exporter 'import';

use Errno         ();
use File::Spec    ();
use Scalar::Util  ();

use Voxgig::Plugin::Types ();

our @EXPORT_OK = qw(providerplugin builtins kinds PROVIDER_EXPORT ERROR_CODE);

# Loaded lazily inside the subs below: Voxgig::Sekreto uses this module, so
# a `use` here would be a cycle.
sub envkey    { return Voxgig::Sekreto::envkey(@_) }
sub checkname { return Voxgig::Sekreto::checkname(@_) }
sub fail      { return Voxgig::Sekreto::fail(@_) }

# Environment variables: `api.token` from `API_TOKEN`.
{

    package Voxgig::Sekreto::Providers::Env;

    sub new {
        my ( $class, $prefix, $source ) = @_;
        return bless { prefix => $prefix, source => $source }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;
        my $key    = Voxgig::Sekreto::Providers::envkey( $name, $self->{prefix} );
        my $source = $self->{source} || \%ENV;
        return $source->{$key};
    }

    sub describe {
        my ($self) = @_;
        return 'env' . ( $self->{prefix} ? ':' . $self->{prefix} : '' );
    }
}

# A `.env` file, read once, keyed exactly like the environment.
{

    package Voxgig::Sekreto::Providers::Dotenv;

    sub new {
        my ( $class, $file, $prefix ) = @_;
        return bless { file => $file, prefix => $prefix, values => undef }, $class;
    }

    sub load {
        my ($self) = @_;

        if ( !defined $self->{values} ) {
            my $text = '';

            if ( open( my $handle, '<', $self->{file} ) ) {
                local $/ = undef;
                $text = <$handle>;
                close($handle);
            }
            else {
                # An absent file - or an absent directory - means "no secrets
                # here", exactly like the file provider. Anything else
                # (permission denied, an unreadable mount) is a store that
                # could not answer, and swallowing it would fall through to a
                # weaker store.
                if ( !( $!{ENOENT} || $!{ENOTDIR} ) ) {
                    Voxgig::Sekreto::Providers::fail(
                        'sekreto: dotenv provider cannot read ' . $self->{file} . ': ' . $! );
                }
            }

            $self->{values} = Voxgig::Sekreto::parsedotenv($text);
        }

        return $self->{values};
    }

    sub lookup {
        my ( $self, $name ) = @_;
        return $self->load()->{ Voxgig::Sekreto::Providers::envkey( $name, $self->{prefix} ) };
    }

    sub describe {
        my ($self) = @_;
        return 'dotenv:' . $self->{file};
    }
}

# Literal values, keyed like environment variables. The spec uses this to
# test chain behaviour without touching the outside world.
{

    package Voxgig::Sekreto::Providers::Memory;

    sub new {
        my ( $class, $values, $prefix ) = @_;
        return bless { values => $values || {}, prefix => $prefix }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;
        return $self->{values}{ Voxgig::Sekreto::Providers::envkey( $name, $self->{prefix} ) };
    }

    sub describe {
        my ($self) = @_;
        return 'memory' . ( $self->{prefix} ? ':' . $self->{prefix} : '' );
    }
}

# A directory of one-secret-per-file entries, keyed like the environment:
# `api.token` reads `<dir>/API_TOKEN`.
#
# This is the shape of a mounted Kubernetes Secret, a Docker or Swarm
# secret, and a systemd credentials directory, so those all work with no
# further configuration. One trailing newline is stripped - tools that
# write these files disagree about it, and a newline is never part of a
# secret on purpose.
{

    package Voxgig::Sekreto::Providers::File;

    sub new {
        my ( $class, $dir, $prefix ) = @_;
        return bless { dir => $dir, prefix => $prefix }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;

        my $file = File::Spec->catfile( $self->{dir},
            Voxgig::Sekreto::Providers::envkey( $name, $self->{prefix} ) );

        my $handle;
        if ( !open( $handle, '<', $file ) ) {

            # An absent file - or an absent directory - means "no secrets
            # here", exactly like a missing .env. Anything else (permission
            # denied, an unreadable mount) is a store that could not answer.
            return undef if $!{ENOENT} || $!{ENOTDIR};

            Voxgig::Sekreto::Providers::fail(
                'sekreto: file provider cannot read ' . $file . ': ' . $! );
        }

        local $/ = undef;
        my $text = <$handle>;
        close($handle);

        $text = '' if !defined $text;
        $text =~ s/\r?\n\z//;

        return $text;
    }

    sub describe {
        my ($self) = @_;
        return 'file:' . $self->{dir};
    }
}
# --- providers as voxgig/plugin definitions ------------------------------

# The export key under which a provider definition publishes the provider
# it built. `Sekreto` reads `<ref>/provider` off the host.
sub PROVIDER_EXPORT { return 'provider' }

# The voxgig/plugin error code a SekretoError travels under when it is
# raised inside a definition's `define`.
#
# plugin wraps a code-less error raised by a callback as
# `plugin_define_failed`, and keeps an error that already carries a code.
# A provider that refuses its own configuration - `kv: 3`, a missing
# project - raises a SekretoError, and that message is pinned by the spec
# byte for byte, so it must come back out of the host exactly as it went
# in. `providerplugin` gives it this code on the way in; `Sekreto` turns it
# back into a SekretoError on the way out.
sub ERROR_CODE { return 'sekreto_error' }

# A provider kind, as a voxgig/plugin definition.
#
# This is the whole bridge between the two libraries. The definition's
# `name` is the `kind` a spec names; its `define` reads the spec as
# `$inst->options`, builds the provider with `$make`, and exports it.
# Nothing runs at `activate`: a provider opens nothing until its first
# lookup, so there is nothing to capture - a provider that does hold a
# resource acquires it there and lets the instance scope unwind it.
#
# Every built-in and every plugin is made this way, so a custom provider
# kind is one call:
#
#     providerplugin( 'mystore', sub { MyStore->new( $_[0]->{addr} ) } )
sub providerplugin {
    my ( $kind, $make ) = @_;

    return {
        name   => $kind,
        define => sub {
            my ($inst) = @_;

            my $provider;
            my $ok = eval { $provider = $make->( $inst->options ); 1 };

            if ( !$ok ) {
                my $err = $@;

                # A SekretoError, and only a SekretoError, is given the
                # code that carries it back out unchanged. Anything else
                # is not sekreto's to rewrite: plugin wraps it as
                # `plugin_define_failed`, naming the instance.
                die $err
                  if !( Scalar::Util::blessed($err)
                    && $err->isa('Voxgig::Sekreto::SekretoError') );

                Voxgig::Plugin::Types::fail_with( ERROR_CODE(), "$err",
                    { ref => $inst->ref, cause => "$err" } );
            }

            $inst->export( PROVIDER_EXPORT(), $provider );
            return;
        },
    };
}

# The four built-in provider kinds - the same four in every port. What
# makes a kind built in is that it needs nothing of the platform beyond
# reading a local file: no socket, no TLS, no crypto, no child process.
sub builtins {
    return [
        providerplugin( 'env', sub { Voxgig::Sekreto::Providers::Env->new( $_[0]->{prefix} ) } ),
        providerplugin(
            'memory',
            sub {
                Voxgig::Sekreto::Providers::Memory->new( $_[0]->{values} || {}, $_[0]->{prefix} );
            }
        ),
        providerplugin(
            'dotenv',
            sub {
                Voxgig::Sekreto::Providers::Dotenv->new( $_[0]->{file} || '.env',
                    $_[0]->{prefix} );
            }
        ),
        providerplugin(
            'file',
            sub {
                Voxgig::Sekreto::Providers::File->new( $_[0]->{dir} || '', $_[0]->{prefix} );
            }
        ),
    ];
}

# Every kind this library ships, built in or as a plugin, so that an
# unknown kind can be told from a plugin that was not passed in.
sub kinds {
    return {
        builtin => [qw(env memory dotenv file)],
        plugin  => [
            qw(hashicorp boru awssecrets awsparams gcpsecrets
              azuresecrets onepassword doppler infisical secretspec)
        ],
    };
}

1;
