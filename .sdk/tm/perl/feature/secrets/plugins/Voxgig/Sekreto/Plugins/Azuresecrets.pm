# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Azuresecrets.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Azuresecrets;

# The azuresecrets plugin: Azure Key Vault over its REST API.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# A port of typescript/plugins/azuresecrets.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Addr ();
use Voxgig::Sekreto::Plugins::Httpjson ();

our @EXPORT_OK = qw(azuresecrets);

# Azure Key Vault.
#
# `api.token` reads secret `api-token` (dots flattened to `-`; Key Vault
# names allow nothing else), current version. The token comes from config,
# then a client-credentials login when tenant/clientid/clientsecret are
# given, then the IMDS managed-identity endpoint - so on Azure's own
# platform no credential configuration is needed.
#
# As with GCP, the IMDS call is plain http to a link-local host by
# platform design and carries no credential; the login and vault addresses
# are `checkaddr`-guarded.
{

    package Voxgig::Sekreto::Plugins::Azuresecrets::Provider;

    my $RESOURCE = 'https://vault.azure.net';

    # A configured token is kept forever; logged-in and IMDS tokens carry
    # expires_in and are renewed shortly before they run out.
    sub new {
        my ( $class, $opts ) = @_;
        return bless { opts => $opts || {}, livetoken => undef, renewat => undef }, $class;
    }

    sub login {
        my ($self) = @_;
        my $opts = $self->{opts};

        return $opts->{token} if $opts->{token};

        if ( $opts->{tenant} && $opts->{clientid} && $opts->{clientsecret} ) {
            my $loginaddr = $opts->{loginaddr} || 'https://login.microsoftonline.com';
            Voxgig::Sekreto::Addr::checkaddr($loginaddr);

            ( my $base = $loginaddr ) =~ s{/$}{};
            my $url = $base . '/' . $opts->{tenant} . '/oauth2/v2.0/token';
            my $form =
                'grant_type=client_credentials&client_id='
              . Voxgig::Sekreto::Plugins::Httpjson::urlenc( $opts->{clientid} )
              . '&client_secret='
              . Voxgig::Sekreto::Plugins::Httpjson::urlenc( $opts->{clientsecret} )
              . '&scope='
              . Voxgig::Sekreto::Plugins::Httpjson::urlenc( $RESOURCE . '/.default' );

            my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'POST', $url,
                { 'content-type' => 'application/x-www-form-urlencoded' }, $form );

            my $got = 'HASH' eq ref( $body || '' ) ? $body->{access_token} : undef;

            Voxgig::Sekreto::fail( 'sekreto: azure login failed: ' . $status )
              if 200 != $status || !$got;

            $self->{renewat} = Voxgig::Sekreto::Plugins::Httpjson::renewafter( $body->{expires_in} );

            return Voxgig::Sekreto::Plugins::Httpjson::stringof($got);
        }

        ( my $imdsbase = $opts->{imdsaddr} || 'http://169.254.169.254' ) =~ s{/$}{};
        my $imds =
            $imdsbase
          . '/metadata/identity/oauth2/token?api-version=2018-02-01&resource='
          . Voxgig::Sekreto::Plugins::Httpjson::urlenc($RESOURCE);

        my ( $status, $body ) =
          Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET', $imds, { 'Metadata' => 'true' } );

        my $got = 'HASH' eq ref( $body || '' ) ? $body->{access_token} : undef;

        Voxgig::Sekreto::fail(
            'sekreto: azure: no token, no client credentials, and IMDS did not answer')
          if 200 != $status || !$got;

        $self->{renewat} = Voxgig::Sekreto::Plugins::Httpjson::renewafter( $body->{expires_in} );

        return Voxgig::Sekreto::Plugins::Httpjson::stringof($got);
    }

    sub lookup {
        my ( $self, $name ) = @_;
        my $opts = $self->{opts};

        my $vault = $opts->{vault} || '';
        Voxgig::Sekreto::fail('sekreto: azure: no vault') if '' eq $vault;

        # Only an explicit scheme is a URL; a vault NAMED httpvault must
        # still become https://httpvault.vault.azure.net.
        my $vaulturl =
          ( 0 == index( $vault, 'http://' ) || 0 == index( $vault, 'https://' ) )
          ? $vault
          : 'https://' . $vault . '.vault.azure.net';
        Voxgig::Sekreto::Addr::checkaddr($vaulturl);

        $self->{livetoken} = $self->login()
          if !defined $self->{livetoken}
          || Voxgig::Sekreto::Plugins::Httpjson::renewdue( $self->{renewat} );

        ( my $base = $vaulturl ) =~ s{/$}{};
        my $url =
            $base
          . '/secrets/'
          . Voxgig::Sekreto::flatname( $name, '-' )
          . '?api-version='
          . ( $opts->{apiversion} || '7.4' );

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET', $url,
            { 'authorization' => 'Bearer ' . $self->{livetoken} } );

        return undef if 404 == $status;

        if ( 200 != $status ) {
            ( my $plain = $url ) =~ s/\?.*//s;
            Voxgig::Sekreto::fail(
                'sekreto: azure error: ' . $status . ': ' . $plain );
        }

        my $value = 'HASH' eq ref( $body || '' ) ? $body->{value} : undef;
        return Voxgig::Sekreto::Plugins::Httpjson::stringof($value);
    }

    sub describe {
        my ($self) = @_;
        return 'azuresecrets:' . ( $self->{opts}{vault} || '' );
    }
}


# The plugin: the `azuresecrets` provider kind, as a voxgig/plugin
# definition.
sub azuresecrets {
    return providerplugin( 'azuresecrets',
        sub { Voxgig::Sekreto::Plugins::Azuresecrets::Provider->new( $_[0] ) } );
}

1;
