# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Infisical.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Infisical;

# The infisical plugin: Infisical over its REST API.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# A port of typescript/plugins/infisical.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use JSON::PP ();

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Addr ();
use Voxgig::Sekreto::Plugins::Httpjson ();

our @EXPORT_OK = qw(infisical);

# Infisical.
#
# `api.token` reads the secret keyed `API_TOKEN` (Infisical's own
# convention is environment-style keys) at a secret path in one
# environment of a project. Auth is a token, or a universal-auth (machine
# identity) login with clientid/clientsecret.
{

    package Voxgig::Sekreto::Plugins::Infisical::Provider;

    # A configured token is kept forever; a universal-auth token carries
    # expiresIn and is renewed shortly before it runs out.
    sub new {
        my ( $class, $opts ) = @_;
        return bless { opts => $opts || {}, livetoken => undef, renewat => undef }, $class;
    }

    sub login {
        my ( $self, $addr ) = @_;
        my $opts = $self->{opts};

        return $opts->{token} if $opts->{token};

        Voxgig::Sekreto::fail(
            'sekreto: infisical: no token and no client credentials')
          if !$opts->{clientid} || !$opts->{clientsecret};

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson(
            'POST',
            $addr . '/api/v1/auth/universal-auth/login',
            { 'content-type' => 'application/json' },
            JSON::PP->new->canonical(1)->encode(
                { clientId => $opts->{clientid}, clientSecret => $opts->{clientsecret} }
            )
        );

        my $got = 'HASH' eq ref( $body || '' ) ? $body->{accessToken} : undef;

        Voxgig::Sekreto::fail( 'sekreto: infisical login failed: ' . $status )
          if 200 != $status || !$got;

        $self->{renewat} = Voxgig::Sekreto::Plugins::Httpjson::renewafter( $body->{expiresIn} );

        return Voxgig::Sekreto::Plugins::Httpjson::stringof($got);
    }

    sub lookup {
        my ( $self, $name ) = @_;
        my $opts = $self->{opts};

        ( my $addr = $opts->{addr} || 'https://app.infisical.com' ) =~ s{/$}{};
        Voxgig::Sekreto::Addr::checkaddr($addr);

        my $project     = $opts->{project}     || '';
        my $environment = $opts->{environment} || '';
        Voxgig::Sekreto::fail('sekreto: infisical: no project/environment')
          if '' eq $project || '' eq $environment;

        $self->{livetoken} = $self->login($addr)
          if !defined $self->{livetoken}
          || Voxgig::Sekreto::Plugins::Httpjson::renewdue( $self->{renewat} );

        my $url =
            $addr
          . '/api/v3/secrets/raw/'
          . Voxgig::Sekreto::envkey($name)
          . '?workspaceId='
          . Voxgig::Sekreto::Plugins::Httpjson::urlenc($project)
          . '&environment='
          . Voxgig::Sekreto::Plugins::Httpjson::urlenc($environment)
          . '&secretPath='
          . Voxgig::Sekreto::Plugins::Httpjson::urlenc( $opts->{path} || '/' );

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET', $url,
            { 'authorization' => 'Bearer ' . $self->{livetoken} } );

        return undef if 404 == $status;

        Voxgig::Sekreto::fail( 'sekreto: infisical error: ' . $status )
          if 200 != $status;

        my $value =
          ( 'HASH' eq ref( $body || '' ) && 'HASH' eq ref( $body->{secret} || '' ) )
          ? $body->{secret}{secretValue}
          : undef;

        return Voxgig::Sekreto::Plugins::Httpjson::stringof($value);
    }

    sub describe {
        my ($self) = @_;
        return 'infisical:'
          . ( $self->{opts}{project} || '' ) . '/'
          . ( $self->{opts}{environment} || '' );
    }
}


# The plugin: the `infisical` provider kind, as a voxgig/plugin definition.
sub infisical {
    return providerplugin( 'infisical',
        sub { Voxgig::Sekreto::Plugins::Infisical::Provider->new( $_[0] ) } );
}

1;
