# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Onepassword.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Onepassword;

# The onepassword plugin: 1Password through a Connect server.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# A port of typescript/plugins/onepassword.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Addr ();
use Voxgig::Sekreto::Plugins::Httpjson ();

our @EXPORT_OK = qw(onepassword);

# 1Password, through a Connect server.
#
# The item titled `api.token` (titles keep their dots), in the named
# vault. The value is the field with purpose PASSWORD, or the field
# labelled `value`. A vault that cannot be found is an error - config
# names it, so its absence is a broken store, not a missing secret.
{

    package Voxgig::Sekreto::Plugins::Onepassword::Provider;

    sub new {
        my ( $class, $opts ) = @_;
        return bless { opts => $opts || {}, vaultid => undef }, $class;
    }

    sub authheaders {
        my ($self) = @_;
        return { 'authorization' => 'Bearer ' . ( $self->{opts}{token} || '' ) };
    }

    sub resolvevault {
        my ( $self, $addr ) = @_;

        my $want = $self->{opts}{vault} || '';
        Voxgig::Sekreto::fail('sekreto: onepassword: no vault') if '' eq $want;

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET',
            $addr . '/v1/vaults', $self->authheaders() );

        Voxgig::Sekreto::fail(
            'sekreto: onepassword error: ' . $status . ': listing vaults')
          if 200 != $status || 'ARRAY' ne ref( $body || '' );

        for my $entry (@$body) {
            next if 'HASH' ne ref( $entry || '' );
            return Voxgig::Sekreto::Plugins::Httpjson::stringof( $entry->{id} )
              if ( defined $entry->{id} && !ref( $entry->{id} ) && $want eq $entry->{id} )
              || ( defined $entry->{name} && !ref( $entry->{name} ) && $want eq $entry->{name} );
        }

        Voxgig::Sekreto::fail( 'sekreto: onepassword: no vault named ' . $want );
    }

    sub lookup {
        my ( $self, $name ) = @_;

        Voxgig::Sekreto::checkname($name);

        ( my $addr = $self->{opts}{addr} || '' ) =~ s{/$}{};
        Voxgig::Sekreto::fail('sekreto: onepassword: no addr') if '' eq $addr;
        Voxgig::Sekreto::Addr::checkaddr($addr);

        $self->{vaultid} = $self->resolvevault($addr) if !defined $self->{vaultid};

        my $filter = Voxgig::Sekreto::Plugins::Httpjson::urlenc( 'title eq "' . $name . '"' );
        my ( $status, $found ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET',
            $addr . '/v1/vaults/' . $self->{vaultid} . '/items?filter=' . $filter,
            $self->authheaders() );

        Voxgig::Sekreto::fail(
            'sekreto: onepassword error: ' . $status . ': finding ' . $name )
          if 200 != $status || 'ARRAY' ne ref( $found || '' );

        return undef if 0 == scalar(@$found);

        my ( $itemstatus, $item ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET',
            $addr . '/v1/vaults/' . $self->{vaultid} . '/items/' . $found->[0]{id},
            $self->authheaders() );

        Voxgig::Sekreto::fail(
            'sekreto: onepassword error: ' . $itemstatus . ': reading ' . $name )
          if 200 != $itemstatus;

        my $fields =
          ( 'HASH' eq ref( $item || '' ) && 'ARRAY' eq ref( $item->{fields} || '' ) )
          ? $item->{fields}
          : [];

        for my $field (@$fields) {
            next if 'HASH' ne ref( $field || '' );
            return Voxgig::Sekreto::Plugins::Httpjson::stringof( $field->{value} )
              if defined $field->{purpose} && 'PASSWORD' eq $field->{purpose};
        }
        for my $field (@$fields) {
            next if 'HASH' ne ref( $field || '' );
            return Voxgig::Sekreto::Plugins::Httpjson::stringof( $field->{value} )
              if defined $field->{label} && 'value' eq $field->{label};
        }

        return undef;
    }

    sub describe {
        my ($self) = @_;
        return 'onepassword:' . ( $self->{opts}{vault} || '' );
    }
}


# The plugin: the `onepassword` provider kind, as a voxgig/plugin
# definition.
sub onepassword {
    return providerplugin( 'onepassword',
        sub { Voxgig::Sekreto::Plugins::Onepassword::Provider->new( $_[0] ) } );
}

1;
