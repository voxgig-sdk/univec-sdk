# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Gcpsecrets.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Gcpsecrets;

# The gcpsecrets plugin: GCP Secret Manager over its REST API.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# A port of typescript/plugins/gcpsecrets.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Addr ();
use Voxgig::Sekreto::Plugins::Httpjson ();

our @EXPORT_OK = qw(gcpsecrets);

# GCP Secret Manager.
#
# `api.token` reads secret `api_token` (dots flattened to `_`; Secret
# Manager ids have no hierarchy and reject dots), latest version. The
# token comes from config, then `GOOGLE_OAUTH_ACCESS_TOKEN`, then the
# GCE/GKE metadata server - so on Google's own platform no credential
# configuration is needed at all.
#
# The metadata call itself is plain http to a link-local host by platform
# design; no credential rides on it, so `checkaddr` guards the Secret
# Manager address instead.
{

    package Voxgig::Sekreto::Plugins::Gcpsecrets::Provider;

    # A configured token is kept forever; a metadata-server token carries
    # expires_in and is renewed shortly before it runs out.
    sub new {
        my ( $class, $opts ) = @_;
        return bless { opts => $opts || {}, livetoken => undef, renewat => undef }, $class;
    }

    sub metadataaddr {
        my ($self) = @_;
        return $self->{opts}{metadataaddr} if $self->{opts}{metadataaddr};
        my $host = $ENV{GCE_METADATA_HOST};
        return $host ? 'http://' . $host : 'http://metadata.google.internal';
    }

    sub login {
        my ($self) = @_;

        my $configured = $self->{opts}{token} || $ENV{GOOGLE_OAUTH_ACCESS_TOKEN};
        return $configured if $configured;

        ( my $base = $self->metadataaddr() ) =~ s{/$}{};
        my $url = $base . '/computeMetadata/v1/instance/service-accounts/default/token';

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET', $url,
            { 'Metadata-Flavor' => 'Google' } );

        my $got = 'HASH' eq ref( $body || '' ) ? $body->{access_token} : undef;

        Voxgig::Sekreto::fail(
            'sekreto: gcp: no token and metadata server did not answer')
          if 200 != $status || !$got;

        $self->{renewat} = Voxgig::Sekreto::Plugins::Httpjson::renewafter( $body->{expires_in} );

        return Voxgig::Sekreto::Plugins::Httpjson::stringof($got);
    }

    sub lookup {
        my ( $self, $name ) = @_;

        my $project = $self->{opts}{project} || '';
        Voxgig::Sekreto::fail('sekreto: gcp: no project') if '' eq $project;

        my $addr = $self->{opts}{addr} || 'https://secretmanager.googleapis.com';
        Voxgig::Sekreto::Addr::checkaddr($addr);

        $self->{livetoken} = $self->login()
          if !defined $self->{livetoken}
          || Voxgig::Sekreto::Plugins::Httpjson::renewdue( $self->{renewat} );

        ( my $base = $addr ) =~ s{/$}{};
        my $url =
            $base
          . '/v1/projects/'
          . $project
          . '/secrets/'
          . Voxgig::Sekreto::flatname( $name, '_' )
          . '/versions/latest:access';

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET', $url,
            { 'authorization' => 'Bearer ' . $self->{livetoken} } );

        return undef if 404 == $status;

        Voxgig::Sekreto::fail( 'sekreto: gcp error: ' . $status . ': ' . $url )
          if 200 != $status;

        my $data =
          ( 'HASH' eq ref( $body || '' ) && 'HASH' eq ref( $body->{payload} || '' ) )
          ? $body->{payload}{data}
          : undef;

        return undef if !defined $data || ref($data);

        # See the aws provider: an undecodable payload is an error, not a
        # miss.
        my $decoded = Voxgig::Sekreto::Plugins::Httpjson::unbase64($data);

        Voxgig::Sekreto::fail('sekreto: gcp: undecodable secret')
          if !defined $decoded;

        return $decoded;
    }

    sub describe {
        my ($self) = @_;
        return 'gcpsecrets:' . ( $self->{opts}{project} || '' );
    }
}


# The plugin: the `gcpsecrets` provider kind, as a voxgig/plugin definition.
sub gcpsecrets {
    return providerplugin( 'gcpsecrets',
        sub { Voxgig::Sekreto::Plugins::Gcpsecrets::Provider->new( $_[0] ) } );
}

1;
