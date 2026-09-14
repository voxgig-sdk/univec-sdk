# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Doppler.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Doppler;

# The doppler plugin: a Doppler config, downloaded once and answered from
# memory.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# A port of typescript/plugins/doppler.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Addr ();
use Voxgig::Sekreto::Plugins::Httpjson ();

our @EXPORT_OK = qw(doppler);

# Doppler.
#
# The whole config is downloaded once - Doppler's own bulk endpoint - and
# answered from memory, like a remote .env: `api.token` is the `API_TOKEN`
# entry. A service token is config-scoped, so project and config are only
# needed with broader tokens.
{

    package Voxgig::Sekreto::Plugins::Doppler::Provider;

    sub new {
        my ( $class, $opts ) = @_;
        return bless { opts => $opts || {}, values => undef }, $class;
    }

    sub load {
        my ($self) = @_;

        return $self->{values} if defined $self->{values};

        ( my $addr = $self->{opts}{addr} || 'https://api.doppler.com' ) =~ s{/$}{};
        Voxgig::Sekreto::Addr::checkaddr($addr);

        my $url = $addr . '/v3/configs/config/secrets/download?format=json';
        $url .= '&project=' . Voxgig::Sekreto::Plugins::Httpjson::urlenc( $self->{opts}{project} )
          if $self->{opts}{project};
        $url .= '&config=' . Voxgig::Sekreto::Plugins::Httpjson::urlenc( $self->{opts}{config} )
          if $self->{opts}{config};

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET', $url,
            { 'authorization' => 'Bearer ' . ( $self->{opts}{token} || '' ) } );

        Voxgig::Sekreto::fail( 'sekreto: doppler error: ' . $status )
          if 200 != $status || 'HASH' ne ref( $body || '' );

        my %values;
        for my $key ( keys %$body ) {
            $values{$key} = Voxgig::Sekreto::Plugins::Httpjson::stringof( $body->{$key} )
              if defined $body->{$key};
        }
        $self->{values} = \%values;

        return $self->{values};
    }

    sub lookup {
        my ( $self, $name ) = @_;
        return $self->load()->{ Voxgig::Sekreto::envkey($name) };
    }

    sub describe {
        my ($self) = @_;
        my $opts = $self->{opts};
        return 'doppler'
          . ( $opts->{project} ? ':' . $opts->{project} . '/' . ( $opts->{config} || '' ) : '' );
    }
}


# The plugin: the `doppler` provider kind, as a voxgig/plugin definition.
sub doppler {
    return providerplugin( 'doppler',
        sub { Voxgig::Sekreto::Plugins::Doppler::Provider->new( $_[0] ) } );
}

1;
