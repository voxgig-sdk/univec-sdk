# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Hashicorp.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Hashicorp;

# The hashicorp plugin: HashiCorp Vault over its HTTP API.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# A port of typescript/plugins/hashicorp.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use JSON::PP ();

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Addr ();
use Voxgig::Sekreto::Plugins::Httpjson ();

our @EXPORT_OK = qw(hashicorp);

# HashiCorp Vault.
#
# KV v2 (the default): `api.token` reads `{addr}/v1/{mount}/data/api` and
# takes the `token` field of `data.data`. KV v1 (`kv: 1`) reads
# `{addr}/v1/{mount}/api` and takes the field of `data`. A 404 means "not
# here" - a miss - so a vault can sit in a chain with fallbacks.
#
# A Vault Enterprise namespace rides the X-Vault-Namespace header, on
# logins as well as reads.
#
# Instead of being handed a token, the provider can log in: Kubernetes
# auth (the pod's service-account JWT, from its conventional path) or
# AppRole. A failed login is an error, never a miss - it means this store
# could not answer at all.
{

    package Voxgig::Sekreto::Plugins::Hashicorp::Provider;

    sub new {
        my ( $class, $addr, $token, $options ) = @_;

        my $opts = $options || {};
        my $usetoken = defined $token ? $token : '';
        my $kv = $opts->{kv} || 2;

        # A version typo like kv: 3 must not quietly behave as v2 and turn
        # its 404s into misses; there is nothing safe to assume it meant.
        Voxgig::Sekreto::fail(
            'sekreto: hashicorp: unsupported kv version: ' . $kv )
          if 1 != $kv && 2 != $kv;

        return bless {
            addr           => defined $addr ? $addr : '',
            mount          => $opts->{mount} || 'secret',
            kv             => $kv,
            vaultnamespace => $opts->{vaultnamespace},
            auth           => $opts->{auth},

            # The working token: a configured token is kept forever, a
            # logged-in token is renewed shortly before its lease runs
            # out - a long-running process must not keep presenting a
            # token the vault already expired.
            livetoken => '' eq $usetoken ? undef : $usetoken,
            renewat   => undef,
        }, $class;
    }

    sub baseheaders {
        my ($self) = @_;
        my %headers;
        $headers{'X-Vault-Namespace'} = $self->{vaultnamespace} if $self->{vaultnamespace};
        return \%headers;
    }

    sub login {
        my ($self) = @_;

        my $auth = $self->{auth};
        Voxgig::Sekreto::fail('sekreto: hashicorp: no token and no auth method')
          if !$auth;

        my $method = defined $auth->{method} ? $auth->{method} : '';
        my $mount = $auth->{mount} || $method;

        ( my $addr = $self->{addr} ) =~ s{/$}{};
        my $url = $addr . '/v1/auth/' . $mount . '/login';

        my $body;
        if ( 'kubernetes' eq $method ) {
            my $jwt = $auth->{jwt};
            if ( !defined $jwt ) {
                my $file = $auth->{jwtfile}
                  || '/var/run/secrets/kubernetes.io/serviceaccount/token';
                my $handle;
                Voxgig::Sekreto::fail(
                    'sekreto: hashicorp: cannot read jwt file ' . $file )
                  if !open( $handle, '<', $file );
                local $/ = undef;
                $jwt = <$handle>;
                close($handle);
                $jwt = '' if !defined $jwt;
                $jwt =~ s/^\s+|\s+$//g;
            }
            $body = { role => ( defined $auth->{role} ? $auth->{role} : '' ), jwt => $jwt };
        }
        elsif ( 'approle' eq $method ) {
            $body = {
                role_id   => defined $auth->{roleid}   ? $auth->{roleid}   : '',
                secret_id => defined $auth->{secretid} ? $auth->{secretid} : '',
            };
        }
        else {
            Voxgig::Sekreto::fail(
                'sekreto: hashicorp: unknown auth method: ' . $method );
        }

        my ( $status, $resbody ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson(
            'POST', $url,
            $self->baseheaders(),
            JSON::PP->new->canonical(1)->encode($body)
        );

        my $got =
          ( 'HASH' eq ref( $resbody || '' ) && 'HASH' eq ref( $resbody->{auth} || '' ) )
          ? $resbody->{auth}{client_token}
          : undef;

        Voxgig::Sekreto::fail(
            'sekreto: hashicorp login failed: ' . $status . ': ' . $url )
          if 200 != $status || !$got;

        $self->{renewat} =
          Voxgig::Sekreto::Plugins::Httpjson::renewafter( $resbody->{auth}{lease_duration} );

        return Voxgig::Sekreto::Plugins::Httpjson::stringof($got);
    }

    sub lookup {
        my ( $self, $name ) = @_;

        Voxgig::Sekreto::Addr::checkaddr( $self->{addr} );

        $self->{livetoken} = $self->login()
          if !defined $self->{livetoken}
          || Voxgig::Sekreto::Plugins::Httpjson::renewdue( $self->{renewat} );

        my $ref = Voxgig::Sekreto::vaultref($name);

        ( my $addr = $self->{addr} ) =~ s{/$}{};
        my $base = $addr . '/v1/' . $self->{mount};
        my $url =
          1 == $self->{kv} ? $base . '/' . $ref->{path} : $base . '/data/' . $ref->{path};

        my $headers = $self->baseheaders();
        $headers->{'X-Vault-Token'} = $self->{livetoken};

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'GET', $url, $headers );

        return undef if 404 == $status;

        Voxgig::Sekreto::fail(
            'sekreto: hashicorp error: ' . $status . ': ' . $url )
          if 200 != $status;

        my $data;
        if ( 1 == $self->{kv} ) {
            $data = 'HASH' eq ref( $body || '' ) ? $body->{data} : undef;
        }
        else {
            $data =
              ( 'HASH' eq ref( $body || '' ) && 'HASH' eq ref( $body->{data} || '' ) )
              ? $body->{data}{data}
              : undef;
        }

        my $value = 'HASH' eq ref( $data || '' ) ? $data->{ $ref->{field} } : undef;
        return Voxgig::Sekreto::Plugins::Httpjson::stringof($value);
    }

    sub describe {
        my ($self) = @_;
        return 'hashicorp:' . $self->{addr} . '/' . $self->{mount};
    }
}

# The plugin: the `hashicorp` provider kind, as a voxgig/plugin definition.
sub hashicorp {
    return providerplugin(
        'hashicorp',
        sub {
            my ($spec) = @_;
            return Voxgig::Sekreto::Plugins::Hashicorp::Provider->new(
                $spec->{addr}  || '',
                $spec->{token} || '',
                {
                    mount          => $spec->{mount},
                    kv             => $spec->{kv},
                    vaultnamespace => $spec->{vaultnamespace},
                    auth           => $spec->{auth},
                }
            );
        }
    );
}

1;
