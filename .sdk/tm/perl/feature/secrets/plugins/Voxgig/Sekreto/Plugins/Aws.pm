# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/plugins/Voxgig/Sekreto/Plugins/Aws.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Aws;

# The aws plugins: Secrets Manager and SSM Parameter Store, both reached
# with SigV4-signed requests.
#
# NOT IN THE CORE. A `Sekreto` can build this kind only if the calling
# project passed this definition in through the `plugins` option; the
# core loads nothing under `plugins/` (docs/design/plugin-providers.md).
#
# `sigv4` travels with them - it is the crypto edge, and the two kinds here
# are its only callers - and is re-exported so that one `use` gets a caller
# the signing function and the kinds together.
#
# A port of typescript/plugins/aws.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use JSON::PP ();

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(providerplugin);
use Voxgig::Sekreto::Addr ();
use Voxgig::Sekreto::Plugins::Httpjson ();
use Voxgig::Sekreto::Plugins::Sigv4 ();

our @EXPORT_OK = qw(awssecrets awsparams sigv4);

# Called by name rather than imported, the way every module here reaches the
# core: Voxgig::Sekreto is loaded by every consumer of this one.
sub fail { return Voxgig::Sekreto::fail(@_) }

# The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now.
sub awsnow {
    my @t = gmtime();
    return sprintf( '%04d%02d%02dT%02d%02d%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0] );
}

# Region and credentials, from config first and the standard AWS_*
# environment variables second - those are AWS's own convention, and a pod
# or CI job that has them set should just work. Missing either is an
# error: an AWS store with no credentials could not answer.
sub awsauth {
    my ($opts) = @_;

    my $region  = $opts->{region} || $ENV{AWS_REGION} || $ENV{AWS_DEFAULT_REGION} || '';
    my $keyid   = $opts->{keyid} || $ENV{AWS_ACCESS_KEY_ID} || '';
    my $secret  = $opts->{secret} || $ENV{AWS_SECRET_ACCESS_KEY} || '';
    my $session = $opts->{session} || $ENV{AWS_SESSION_TOKEN} || undef;

    fail('sekreto: aws: no region (set region or AWS_REGION)') if '' eq $region;

    fail(   'sekreto: aws: no credentials'
          . ' (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)' )
      if '' eq $keyid || '' eq $secret;

    return { region => $region, keyid => $keyid, secret => $secret, session => $session };
}

# One signed call to an AWS JSON-1.1 API.
sub awscall {
    my ( $opts, $service, $target, $payload ) = @_;

    my $auth = awsauth($opts);

    # The China partition lives under its own suffix; every other
    # commercial region is plain amazonaws.com.
    my $suffix =
      0 == index( $auth->{region}, 'cn-' ) ? '.amazonaws.com.cn' : '.amazonaws.com';
    my $addr = $opts->{addr} || 'https://' . $service . '.' . $auth->{region} . $suffix;
    Voxgig::Sekreto::Addr::checkaddr($addr);

    ( my $base = $addr ) =~ s{/$}{};
    my $url  = $base . '/';
    my $body = JSON::PP->new->canonical(1)->encode($payload);

    my %headers = (
        'content-type' => 'application/x-amz-json-1.1',
        'x-amz-target' => $target,
    );

    my $signed = Voxgig::Sekreto::Plugins::Sigv4::sigv4(
        {
            method   => 'POST',
            url      => $url,
            headers  => {%headers},
            body     => $body,
            service  => $service,
            region   => $auth->{region},
            keyid    => $auth->{keyid},
            secret   => $auth->{secret},
            session  => $auth->{session},
            datetime => awsnow(),
        }
    );

    return Voxgig::Sekreto::Plugins::Httpjson::fetchjson( 'POST', $url,
        { %headers, %$signed }, $body );
}

# Does this AWS error body name one of the not-found types? Those are a
# miss; every other failure is a store that could not answer.
sub awsmiss {
    my ( $body, $types ) = @_;

    my $errtype =
      ( 'HASH' eq ref( $body || '' ) && defined $body->{__type} && !ref( $body->{__type} ) )
      ? $body->{__type}
      : '';

    for my $name (@$types) {
        return 1 if index( $errtype, $name ) >= 0;
    }

    return 0;
}

# AWS Secrets Manager.
#
# `api.token` reads the secret named `api` (the vaultref path, so
# `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
# SecretString - the AWS idiom of one JSON map per secret. A SecretString
# that is not JSON is the value itself, under the conventional field
# `value`. Requests are SigV4-signed in-tree; see Sigv4.pm.
{

    package Voxgig::Sekreto::Plugins::Aws::Secrets;

    sub new {
        my ( $class, $opts ) = @_;
        return bless { opts => $opts || {} }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;

        my $ref = Voxgig::Sekreto::vaultref($name);

        my ( $status, $body ) =
          Voxgig::Sekreto::Plugins::Aws::awscall( $self->{opts}, 'secretsmanager',
            'secretsmanager.GetSecretValue', { SecretId => $ref->{path} } );

        return undef
          if 400 == $status
          && Voxgig::Sekreto::Plugins::Aws::awsmiss( $body, ['ResourceNotFoundException'] );

        Voxgig::Sekreto::fail( 'sekreto: aws secretsmanager error: ' . $status )
          if 200 != $status;

        my $text = 'HASH' eq ref( $body || '' ) ? $body->{SecretString} : undef;

        if ( !defined $text || ref($text) ) {

            # A binary secret has no fields to address; only the conventional
            # `value` field can mean "the bytes themselves".
            my $bin = 'HASH' eq ref( $body || '' ) ? $body->{SecretBinary} : undef;
            if ( defined $bin && !ref($bin) && 'value' eq $ref->{field} ) {
                my $decoded = Voxgig::Sekreto::Plugins::Httpjson::unbase64($bin);

                # A store that answered incoherently could not answer.
                Voxgig::Sekreto::fail(
                    'sekreto: aws secretsmanager: undecodable secret')
                  if !defined $decoded;

                return $decoded;
            }
            return undef;
        }

        my $parsed = eval { JSON::PP->new->decode($text) };

        if ( 'HASH' eq ref( $parsed || '' ) ) {
            my $value = $parsed->{ $ref->{field} };
            return Voxgig::Sekreto::Plugins::Httpjson::stringof($value);
        }

        # A plain-string secret is the whole value; it has no named fields.
        return 'value' eq $ref->{field} ? $text : undef;
    }

    sub describe {
        my ($self) = @_;

        # Config only, never the environment: describe() feeds the spec's
        # sources group, which must answer the same everywhere.
        return 'awssecrets:' . ( $self->{opts}{region} || '' );
    }
}

# AWS SSM Parameter Store.
#
# `db.pass.main` reads the parameter `/db/pass/main` (under an optional
# prefix path), decrypted. Parameter Store carries flat strings, so there
# is no field indirection.
{

    package Voxgig::Sekreto::Plugins::Aws::Params;

    sub new {
        my ( $class, $opts ) = @_;
        return bless { opts => $opts || {} }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;

        my ( $status, $body ) = Voxgig::Sekreto::Plugins::Aws::awscall(
            $self->{opts}, 'ssm',
            'AmazonSSM.GetParameter',
            {
                Name => Voxgig::Sekreto::awsparam( $name, $self->{opts}{prefix} ),
                WithDecryption => JSON::PP::true,
            }
        );

        return undef
          if 400 == $status
          && Voxgig::Sekreto::Plugins::Aws::awsmiss( $body, ['ParameterNotFound'] );

        Voxgig::Sekreto::fail( 'sekreto: aws ssm error: ' . $status )
          if 200 != $status;

        my $value =
          ( 'HASH' eq ref( $body || '' ) && 'HASH' eq ref( $body->{Parameter} || '' ) )
          ? $body->{Parameter}{Value}
          : undef;

        return Voxgig::Sekreto::Plugins::Httpjson::stringof($value);
    }

    sub describe {
        my ($self) = @_;
        return 'awsparams:' . ( $self->{opts}{region} || '' ) . ( $self->{opts}{prefix} || '' );
    }
}


# Signing, from the module it lives in. A glob assignment is a single
# mention of the name, which `use warnings` reads as a probable typo; it is
# not, the alias IS the re-export.
no warnings 'once';
*sigv4 = \&Voxgig::Sekreto::Plugins::Sigv4::sigv4;
use warnings 'once';

# The plugins: the `awssecrets` and `awsparams` provider kinds, as
# voxgig/plugin definitions.
sub awssecrets {
    return providerplugin( 'awssecrets',
        sub { Voxgig::Sekreto::Plugins::Aws::Secrets->new( $_[0] ) } );
}

sub awsparams {
    return providerplugin( 'awsparams',
        sub { Voxgig::Sekreto::Plugins::Aws::Params->new( $_[0] ) } );
}

1;
