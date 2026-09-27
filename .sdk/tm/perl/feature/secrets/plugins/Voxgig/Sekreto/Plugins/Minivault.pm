# VENDORED: @voxgig/sekreto sdk-20260925-1316-0 (perl/plugins/Voxgig/Sekreto/Plugins/Minivault.pm)
# Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto::Plugins::Minivault;

# The mini vault: every secret a project owns, encrypted, in one file.
#
# A store this library owns outright rather than a client for a server
# somebody else runs. It has a master key and restricted keys, and it is
# the port's worked example of a definition publishing an API beside its
# provider: a chain READS, and writing is a deliberate act with an
# interface of its own.
#
#     use Voxgig::Sekreto::Plugins::Minivault qw(createvault minivault vaultof);
#
#     my $vault = createvault( { file => 'app.skmv', passphrase => $master } );
#     $vault->set( 'api.token', 'tok01' );
#     $vault->grant( { key => 'ci', passphrase => $ci, names => ['api.token'] } );
#
#     my $secrets = Voxgig::Sekreto->new({
#         plugins   => [ minivault() ],
#         providers => [ { kind => 'minivault', file => 'app.skmv',
#                          vaultkey => 'ci', passphrase => $ci } ],
#     });
#
#     $secrets->get('api.token');          # the chain reads
#     vaultof($secrets)->list;             # the API writes
#
# THE FILE FORMAT IS THE CONTRACT, and the vaults committed under
# test/fixture/ pin it: a vault written by any port is read by every other.
#
#     magic       4   'SKMV'
#     version     1   FORMAT
#     kdf         1   1 = PBKDF2-HMAC-SHA256
#     cipher      1   1 = AES-256-GCM
#     reserved    1   0
#     keycount    4   uint32
#     per key:
#       id        1 + bytes            the key id, PLAINTEXT
#       salt      1 + bytes
#       iters     4                    PBKDF2 rounds for this key
#       ring      1 + iv, 4 + bytes    sealed under the passphrase
#       meta      1 + iv, 4 + bytes    sealed under the vault's meta key
#     entrycount  4   uint32
#     per entry:
#       id        1 + bytes            the blinded lookup id
#       name      1 + iv, 4 + bytes    sealed under the vault's name key
#       value     1 + iv, 4 + bytes    sealed under that secret's own key
#
# Integers are big-endian and every length precedes its bytes, so the file
# is written with the same two primitives it is read with.
#
# NOTHING OUTSIDE A KEY RECORD IS PLAINTEXT. Secret names are sealed, and
# an entry is addressed by a blinded id derived from its own key, so a
# restricted key finds what it was granted without the file ever naming
# the rest. What the file does show anyone is the key ids and how many
# secrets there are.
#
# A port of typescript/plugins/minivault.ts, which is canonical.

use strict;
use warnings;

use Exporter 'import';

use Fcntl        ();
use JSON::PP     ();
use MIME::Base64 ();
use Scalar::Util ();

use Voxgig::Plugin::Types ();

use Voxgig::Sekreto ();
use Voxgig::Sekreto::Providers qw(PROVIDER_EXPORT ERROR_CODE);

our @EXPORT_OK = qw(minivault openvault createvault vaultof minivaultoptions);

sub MAGIC  { return 'SKMV' }
sub FORMAT { return 1 }

sub KDF_PBKDF2    { return 1 }
sub CIPHER_AESGCM { return 1 }

# AES-256-GCM: 32-byte keys, 12-byte nonces, 16-byte tags.
sub KEYLEN  { return 32 }
sub IVLEN   { return 12 }
sub TAGLEN  { return 16 }
sub SALTLEN { return 16 }

# The PBKDF2-HMAC-SHA256 round count when a caller names none.
sub ITERATIONS { return 210_000 }

# The key id a vault gets when a caller names none.
sub MASTERKEY { return 'master' }

# The export key the vault API is published under, beside the provider.
sub VAULT_EXPORT { return 'vault' }

# Additional authenticated data. Every blob is bound to its PLACE in the
# file, so no ciphertext can be moved: a restricted key's ring cannot be
# relabelled as the master's, and one secret's value cannot be served
# under a name it was never written for.
sub AAD_RING   { return 'skmv1:ring:' }
sub AAD_META   { return 'skmv1:meta:' }
sub AAD_NAME   { return 'skmv1:name' }
sub AAD_SECRET { return 'skmv1:secret:' }

# Everything a master reaches is derived from the root key, so rotating is
# one new random value rather than a re-wrap of each part.
sub LABEL_NAMES { return 'skmv1:names' }
sub LABEL_META  { return 'skmv1:meta' }
sub LABEL_ID    { return 'skmv1:id' }

# The largest key id the format can record.
#
# A length is written in ONE byte. A longer id wraps that byte and the
# writer then appends the whole thing, so every field after it shifts: a
# grant with a 300-character id would replace a working vault with an
# unreadable one, and say nothing. Checked where an id is ACCEPTED, so the
# refusal names the id rather than the file.
sub IDMAX { return 255 }

sub fail { return Voxgig::Sekreto::fail( 'sekreto: minivault: ' . $_[0] ) }

# --- characters in, UTF-8 bytes on disk --------------------------------
#
# THE VAULT TAKES TEXT, and the format stores its UTF-8 encoding, because
# that is what the other twenty ports store: a passphrase, a key id or a
# value that reaches a KDF or a cipher as anything else produces a vault
# none of them can open.
#
# UNCONDITIONALLY, AND NOT ON `utf8::is_utf8`. That flag is an internal
# representation, not a meaning: perl holds the same string of characters
# as Latin-1 bytes or as UTF-8 depending on what has happened to it, and
# `utf8::upgrade` changes it without changing the string. A conversion
# that reads the flag therefore hashes one passphrase two ways, which is
# the defect this replaced. Encoding a copy every time is
# representation-neutral, which is the property that matters, and ASCII -
# every passphrase in the fixtures, and most in the world - is unchanged
# by it.
#
# The cost is the other direction: a scalar that is ALREADY UTF-8 bytes,
# which is what `%ENV` and a file hand back, is encoded twice. So the
# boundary decodes - `cli/sekreto-cli.pl` does it for the three vault
# environment variables - and the library works in characters throughout,
# which is the layering perl asks for anyway.

sub bytesof {
    my ($text) = @_;

    return $text if !defined $text;

    my $copy = $text;
    utf8::encode($copy);

    return $copy;
}

# ...and the other way, for what comes back out of the vault: a decoded
# string, as JSON::PP hands a provider its values. Bytes that are not
# UTF-8 are handed back as they are rather than mangled into replacement
# characters - the vault stored them, so it returns them.
sub textof {
    my ($raw) = @_;

    return $raw if !defined $raw;

    my $copy = $raw;
    return $copy if utf8::decode($copy);

    return $raw;
}

sub checkid {
    my ( $id, $what ) = @_;

    fail($what) if !defined $id || ref($id) || '' eq $id;

    # BYTES, because that is what the one length byte counts.
    fail( 'key id is longer than ' . IDMAX() . ' bytes: ' . substr( $id, 0, 32 ) . '...' )
      if IDMAX() < length( bytesof($id) );

    return $id;
}

# ---------------------------------------------------------- the primitives
#
# CryptX, AND NOTHING WRITTEN HERE. Perl's core has SHA-256 in
# `Digest::SHA` and nothing else the format needs: no AES, no AEAD, no
# PBKDF2, no CSPRNG. So the whole of the cryptography comes from one
# audited module rather than three of them plus a block cipher written in
# this file - which is the thing the dependency rule exists to forbid: a
# table-driven AES passes every known-answer test in the world and still
# hands its key to anyone who can time a cache.
#
# It is the same posture this port already takes for https, and for the
# same reason. `HTTP::Tiny` reaches an https store only where
# `IO::Socket::SSL` is installed; this kind opens a vault only where
# `CryptX` is. Both are stated in README.md, both fail CLOSED with the
# package to install, and neither is ever worked around.
#
# LOADED ON FIRST USE, not at compile time. A consumer that has this
# module on @INC and configures no vault must not be stopped by a missing
# package, and `allplugins` loads every kind whether or not the chain
# names them.

my $CRYPTX;

sub cryptx {
    return $CRYPTX if $CRYPTX;

    my $ok = eval {
        require Crypt::AuthEnc::GCM;
        require Crypt::KeyDerivation;
        require Crypt::Mac::HMAC;
        require Crypt::PRNG;
        1;
    };

    fail(   'no AES-256-GCM available: CryptX must be installed for the mini vault'
          . ' (Debian and Ubuntu call it libcryptx-perl)' )
      if !$ok;

    $CRYPTX = 1;

    return $CRYPTX;
}

sub mac {
    my ( $key, $text ) = @_;
    cryptx();
    return Crypt::Mac::HMAC::hmac( 'SHA256', $key, bytesof($text) );
}

# The key-encryption key a passphrase unwraps a ring with.
sub kek {
    my ( $passphrase, $salt, $iters ) = @_;

    fail( 'unusable round count: ' . $iters ) if 1 > $iters;
    cryptx();

    return Crypt::KeyDerivation::pbkdf2( bytesof($passphrase), $salt, $iters, 'SHA256',
        KEYLEN() );
}

# The key one named secret's value is encrypted with.
#
# DERIVED, never stored, for a master: it holds the root key and so
# reaches every name, including ones written after it was made. A
# restricted key holds the derived keys it was granted and nothing that
# produces another, so every other name is ciphertext to it in exactly the
# way it is to a stranger.
sub secretkey {
    my ( $root, $name ) = @_;
    return mac( $root, AAD_SECRET() . $name );
}

# Where a secret lives in the file, derived from its own key so that
# finding it needs no plaintext name. One-way: an id yields nothing about
# the key that produced it.
sub entryid {
    my ($key) = @_;
    return mac( $key, LABEL_ID() );
}

sub randombytes {
    my ($len) = @_;
    cryptx();
    return Crypt::PRNG::random_bytes($len);
}

# Ciphertext followed by the 16-byte tag, which is where every other
# port's AEAD leaves it and therefore what the format records.
sub seal {
    my ( $key, $plain, $aad ) = @_;

    fail('bad key') if KEYLEN() != length($key);
    cryptx();

    my $iv = randombytes( IVLEN() );
    my ( $body, $tag ) =
      Crypt::AuthEnc::GCM::gcm_encrypt_authenticate( 'AES', $key, $iv, bytesof($aad),
        bytesof($plain) );

    fail('cannot seal') if !defined $body || !defined $tag || TAGLEN() != length($tag);

    return { iv => $iv, blob => $body . $tag };
}

# The plaintext, or a refusal.
#
# A GCM tag that fails to verify is the only evidence there is, and it
# cannot tell a wrong passphrase from a damaged file, so `what` names the
# attempt and the message admits both.
sub unseal {
    my ( $key, $sealed, $aad, $what ) = @_;

    fail( $what . ': truncated' )
      if length( $sealed->{blob} ) < TAGLEN() || IVLEN() != length( $sealed->{iv} );
    fail('bad key') if KEYLEN() != length($key);
    cryptx();

    my $body = substr( $sealed->{blob}, 0, length( $sealed->{blob} ) - TAGLEN() );
    my $tag  = substr( $sealed->{blob}, -TAGLEN() );

    my $plain = Crypt::AuthEnc::GCM::gcm_decrypt_verify( 'AES', $key, $sealed->{iv},
        bytesof($aad), $body, $tag );

    fail($what) if !defined $plain;

    return $plain;
}

# THE COMPACT JSON EVERY PORT WRITES, with its keys in a fixed order.
#
# Perl hash order is randomised per process, so an encoder left to itself
# would write the same ring differently on every run - which is not a
# correctness problem, because a ring is read as an object, and IS a
# reproducibility one. `canonical` sorts the keys, and the sort changes no
# byte count: the ring is SEALED, so the length is what the fixtures pin.
sub jsonof {
    return JSON::PP->new->canonical->utf8->encode( $_[0] );
}

sub parsejson {
    my ( $plain, $what ) = @_;

    my $out = eval { JSON::PP->new->utf8->decode($plain) };

    fail( 'unreadable ' . $what ) if !defined $out || 'HASH' ne ref($out);

    return $out;
}

sub b64 {
    return MIME::Base64::encode_base64( $_[0], '' );
}

# STRICT. A lenient decoder hands back plausible bytes for a corrupted
# payload, and those bytes are then used AS A KEY.
sub unb64 {
    my ( $text, $what ) = @_;

    fail( 'missing ' . $what )
      if !defined $text || ref($text) || $text =~ m{[^A-Za-z0-9+/=]};

    return MIME::Base64::decode_base64($text);
}

# ---------------------------------------------------------------- the file

{
    # A cursor, so that every length check is in one place: a truncated
    # vault is refused rather than read as a short one.
    package Voxgig::Sekreto::Plugins::Minivault::Reader;

    use strict;
    use warnings;

    sub new {
        my ( $class, $raw ) = @_;
        return bless { raw => $raw, at => 0 }, $class;
    }

    # Reads `len` bytes, or refuses.
    #
    # The bound is checked AGAINST WHAT IS LEFT, never by adding the
    # length to the cursor: perl's integers would not wrap here, but the
    # check reads the same in every port and is the one that is right
    # everywhere.
    sub take {
        my ( $self, $len ) = @_;

        Voxgig::Sekreto::Plugins::Minivault::fail('the vault file is truncated')
          if length( $self->{raw} ) - $self->{at} < $len;

        my $out = substr( $self->{raw}, $self->{at}, $len );
        $self->{at} += $len;

        return $out;
    }

    sub u8  { return unpack( 'C', $_[0]->take(1) ) }
    sub u32 { return unpack( 'N', $_[0]->take(4) ) }

    sub small { my ($self) = @_; return $self->take( $self->u8 ) }
    sub large { my ($self) = @_; return $self->take( $self->u32 ) }

    sub sealed {
        my ($self) = @_;
        return { iv => $self->small, blob => $self->large };
    }

    sub left { my ($self) = @_; return length( $self->{raw} ) - $self->{at} }
}

sub readfile {
    my ($raw) = @_;

    my $read = Voxgig::Sekreto::Plugins::Minivault::Reader->new($raw);

    fail('not a vault file') if MAGIC() ne $read->take(4);

    my $version = $read->u8;
    fail( 'unsupported format version: ' . $version ) if FORMAT() != $version;

    my $kdf    = $read->u8;
    my $cipher = $read->u8;
    fail( 'unsupported kdf or cipher: ' . $kdf . '/' . $cipher )
      if KDF_PBKDF2() != $kdf || CIPHER_AESGCM() != $cipher;
    $read->u8;

    my $vault = { keys => [], entries => [] };

    # A COUNT IS BOUNDED BY WHAT IS LEFT. Each record carries at least a
    # few bytes, so a file claiming four billion of them is damaged; the
    # loop would find that out one truncation at a time, and a caller that
    # preallocated would not.
    my $keycount = $read->u32;
    fail('the vault file is truncated') if $read->left < $keycount;

    for ( 1 .. $keycount ) {
        push @{ $vault->{keys} },
          {
            id    => textof( $read->small ),
            salt  => $read->small,
            iters => $read->u32,
            ring  => $read->sealed,
            meta  => $read->sealed,
          };
    }

    my $entrycount = $read->u32;
    fail('the vault file is truncated') if $read->left < $entrycount;

    for ( 1 .. $entrycount ) {
        push @{ $vault->{entries} },
          {
            id    => $read->small,
            name  => $read->sealed,
            value => $read->sealed,
          };
    }

    fail('the vault file has trailing bytes') if 0 != $read->left;

    return $vault;
}

sub writefile {
    my ($vault) = @_;

    my $out = MAGIC() . pack( 'CCCC', FORMAT(), KDF_PBKDF2(), CIPHER_AESGCM(), 0 );

    my $small  = sub { return pack( 'C', length( $_[0] ) ) . $_[0] };
    my $large  = sub { return pack( 'N', length( $_[0] ) ) . $_[0] };
    my $sealed = sub { return $small->( $_[0]->{iv} ) . $large->( $_[0]->{blob} ) };

    $out .= pack( 'N', scalar @{ $vault->{keys} } );

    for my $record ( @{ $vault->{keys} } ) {
        $out .= $small->( bytesof( $record->{id} ) );
        $out .= $small->( $record->{salt} );
        $out .= pack( 'N', $record->{iters} );
        $out .= $sealed->( $record->{ring} );
        $out .= $sealed->( $record->{meta} );
    }

    # SORTED BY ID, which is a blinded value: the file therefore records
    # nothing about the order secrets were written in.
    my @entries = sort { $a->{id} cmp $b->{id} } @{ $vault->{entries} };

    $out .= pack( 'N', scalar @entries );

    for my $record (@entries) {
        $out .= $small->( $record->{id} );
        $out .= $sealed->( $record->{name} );
        $out .= $sealed->( $record->{value} );
    }

    return $out;
}

sub keyrecord {
    my ( $vault, $id ) = @_;

    for my $record ( @{ $vault->{keys} } ) {
        return $record if $id eq $record->{id};
    }

    return undef;
}

sub entryrecord {
    my ( $vault, $id ) = @_;

    for my $record ( @{ $vault->{entries} } ) {
        return $record if $id eq $record->{id};
    }

    return undef;
}

# Is this the same sealed blob, byte for byte?
sub sameseal {
    my ( $left, $right ) = @_;
    return $left->{iv} eq $right->{iv} && $left->{blob} eq $right->{blob};
}

# ------------------------------------------------------- the file on disk

# Writes bytes to a path that is not there yet, and REFUSES one that is.
#
# `O_EXCL` refuses an existing path in ONE syscall and will not follow a
# symlink to make one, and the mode goes on AT CREATION rather than after:
# a chmod once the bytes are written leaves the file readable for as long
# as it takes to write them.
#
# Returns the errno string on failure, so that both callers can name the
# VAULT file - the path a caller configured, not the temporary one of them
# happens to be writing.
sub spill {
    my ( $path, $raw ) = @_;

    my $handle;
    if (
        !sysopen( $handle, $path,
            Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), oct('600') )
      )
    {
        return "$!";
    }

    binmode($handle);

    my $written = syswrite( $handle, $raw );
    my $why = defined $written && length($raw) == $written ? undef : "$!";

    close($handle) or $why ||= "$!";

    return $why;
}

# Writes a vault file that is not there yet, and REFUSES one that is.
sub putnew {
    my ( $path, $vault ) = @_;

    my $why = spill( $path, writefile($vault) );
    return if !defined $why;

    fail( 'vault file already exists: ' . $path ) if -e $path;
    fail( 'cannot write ' . $path . ': ' . $why );

    return;
}

sub readmaybe {
    my ($path) = @_;

    my $handle;
    if ( !open( $handle, '<', $path ) ) {
        return undef if !-e $path;
        fail( 'cannot read ' . $path . ': ' . $! );
    }

    binmode($handle);
    local $/ = undef;
    my $raw = <$handle>;
    close($handle);

    return defined $raw ? $raw : '';
}

# ------------------------------------------------------------- creating

# A new vault: one master key, no secrets.
sub newvault {
    my ( $keyid, $passphrase, $iterations ) = @_;

    my $root = randombytes( KEYLEN() );
    my $salt = randombytes( SALTLEN() );

    my $ring = { v => FORMAT(), write => JSON::PP::true, root => b64($root) };
    my $meta = {
        v      => FORMAT(),
        master => JSON::PP::true,
        write  => JSON::PP::true,
        grants => [],
    };

    return {
        keys => [
            {
                id    => $keyid,
                salt  => $salt,
                iters => $iterations,
                ring  => seal( kek( $passphrase, $salt, $iterations ),
                    jsonof($ring), AAD_RING() . $keyid ),
                meta => seal( mac( $root, LABEL_META() ),
                    jsonof($meta), AAD_META() . $keyid ),
            }
        ],
        entries => [],
    };
}

# One key record: the ring sealed under the passphrase, the metadata
# sealed under the vault's meta key.
sub sealkey {
    my ( $root, $keyid, $passphrase, $iters, $ring, $meta ) = @_;

    my $salt = randombytes( SALTLEN() );

    return {
        id    => $keyid,
        salt  => $salt,
        iters => $iters,
        ring  => seal( kek( $passphrase, $salt, $iters ), jsonof($ring),
            AAD_RING() . $keyid ),
        meta => seal( mac( $root, LABEL_META() ), jsonof($meta), AAD_META() . $keyid ),
    };
}

# AN EMPTY KEY IS NO KEY, so it means `master`.
#
# A CLI reaches here with SEKRETO_VAULT_KEY set and empty, which is what
# an unset shell variable expands to, and an empty id is not a key anyone
# could have granted.
sub wantkey {
    my ($held) = @_;
    return ( !defined $held || ref($held) || '' eq $held ) ? MASTERKEY() : $held;
}

# A detached copy, so that what a caller is handed cannot become what this
# vault believes.
sub copyinfo {
    my ($info) = @_;

    return {
        key    => $info->{key},
        master => $info->{master},
        write  => $info->{write},
        grants => [ @{ $info->{grants} } ],
    };
}

# --------------------------------------------------------------- the vault

{
    # A handle on one vault file, opened as ONE key.
    #
    # Every method answers as that key: `list` shows the names it may
    # read, `get` answers for those and misses on the rest, and the
    # master-only methods refuse for any other key. Nothing is read or
    # derived until the first call that needs the file.
    #
    # `master` and `write` are 1/0, as Perl truth goes, which is what
    # `validname` in the core does with the same question.
    package Voxgig::Sekreto::Plugins::Minivault::Vault;

    use strict;
    use warnings;

    use File::Spec ();

    my $MV = 'Voxgig::Sekreto::Plugins::Minivault';

    sub new {
        my ( $class, $options ) = @_;

        my $opts = $options || {};

        my $self = bless {
            file       => $opts->{file},
            keyid      => $MV->can('wantkey')->( $opts->{key} ),
            passphrase => $opts->{passphrase},
            iterations => $opts->{iterations} || $MV->can('ITERATIONS')->(),
            create     => ( defined $opts->{create} && $opts->{create} ) ? 1 : 0,
            opened     => undef,
        }, $class;

        Voxgig::Sekreto::Plugins::Minivault::fail('a vault needs a file')
          if !defined $self->{file} || ref( $self->{file} ) || '' eq $self->{file};

        Voxgig::Sekreto::Plugins::Minivault::fail('a vault needs a passphrase')
          if !defined $self->{passphrase}
          || ref( $self->{passphrase} )
          || '' eq $self->{passphrase};

        Voxgig::Sekreto::Plugins::Minivault::checkid( $self->{keyid},
            'a vault needs a key id' );

        return $self;
    }

    # The file this handle reads.
    sub file { return $_[0]->{file} }

    # The key id this handle opens with.
    sub key { return $_[0]->{keyid} }

    # Derive the key and read the file NOW rather than at first use.
    sub open {
        my ($self) = @_;
        my ( undef, $opened ) = $self->load;
        return Voxgig::Sekreto::Plugins::Minivault::copyinfo( $opened->{info} );
    }

    # Forget the derived keys. The next call opens again.
    sub close {
        my ($self) = @_;
        $self->{opened} = undef;
        return;
    }

    # The names this key can read, sorted.
    sub list {
        my ($self) = @_;
        my ( $vault, $opened ) = $self->load;

        if ( defined $opened->{root} ) {
            my $namekey = Voxgig::Sekreto::Plugins::Minivault::mac( $opened->{root},
                Voxgig::Sekreto::Plugins::Minivault::LABEL_NAMES() );

            return [
                sort map {
                    Voxgig::Sekreto::Plugins::Minivault::textof(
                        Voxgig::Sekreto::Plugins::Minivault::unseal(
                            $namekey, $_->{name},
                            Voxgig::Sekreto::Plugins::Minivault::AAD_NAME(),
                            'a secret name is damaged'
                        )
                    )
                } @{ $vault->{entries} }
            ];
        }

        # A restricted key has no name key, so it reports the grants it
        # can actually find: the vault never tells it what else is in
        # there.
        return [
            sort grep { defined $self->findentry( $vault, $opened->{grants}{$_} ) }
              @{ $opened->{info}{grants} }
        ];
    }

    sub has {
        my ( $self, $name ) = @_;
        return defined $self->get($name) ? 1 : 0;
    }

    # The value, or undef when the vault does not hold that name or this
    # key was not granted it.
    sub get {
        my ( $self, $name ) = @_;

        Voxgig::Sekreto::checkname($name);
        my ( $vault, $opened ) = $self->load;

        my $key = $self->keyfor( $opened, $name );

        # OUTSIDE THE GRANT IS A MISS, deliberately. The vault answers as
        # the key that opened it, so a name this key cannot read is a name
        # this store does not hold for this caller.
        return undef if !defined $key;

        my $entry = $self->findentry( $vault, $key );
        return undef if !defined $entry;

        return Voxgig::Sekreto::Plugins::Minivault::textof(
            Voxgig::Sekreto::Plugins::Minivault::unseal(
                $key, $entry->{value},
                Voxgig::Sekreto::Plugins::Minivault::AAD_SECRET() . $name,
                'the value of ' . $name . ' is damaged'
            )
        );
    }

    # Write a value. A master writes any name; a restricted key holding
    # `write` overwrites the names it was granted, and creates none.
    sub set {
        my ( $self, $name, $value ) = @_;

        Voxgig::Sekreto::checkname($name);
        Voxgig::Sekreto::Plugins::Minivault::fail( 'a secret value must be text: ' . $name )
          if !defined $value || ref($value);

        my ( $vault, $opened ) = $self->load;

        Voxgig::Sekreto::Plugins::Minivault::fail(
            'key ' . $opened->{info}{key} . ' is read-only' )
          if !$opened->{info}{write};

        my $key = $self->keyfor( $opened, $name );
        Voxgig::Sekreto::Plugins::Minivault::fail(
            'key ' . $opened->{info}{key} . ' was not granted ' . $name )
          if !defined $key;

        my $sealedvalue = Voxgig::Sekreto::Plugins::Minivault::seal( $key, $value,
            Voxgig::Sekreto::Plugins::Minivault::AAD_SECRET() . $name );

        my $id = Voxgig::Sekreto::Plugins::Minivault::entryid($key);
        my $entry = Voxgig::Sekreto::Plugins::Minivault::entryrecord( $vault, $id );

        if ( defined $entry ) {
            $entry->{value} = $sealedvalue;
        }
        else {
            # A NEW NAME NEEDS THE NAME KEY, which only a master holds. So
            # a restricted key with `write` updates what it was granted
            # and cannot grow the vault.
            my $root = $self->rootof( $opened, 'creating the secret ' . $name );

            push @{ $vault->{entries} },
              {
                id   => $id,
                name => Voxgig::Sekreto::Plugins::Minivault::seal(
                    Voxgig::Sekreto::Plugins::Minivault::mac(
                        $root, Voxgig::Sekreto::Plugins::Minivault::LABEL_NAMES()
                    ),
                    $name,
                    Voxgig::Sekreto::Plugins::Minivault::AAD_NAME()
                ),
                value => $sealedvalue,
              };
        }

        $self->save($vault);

        return;
    }

    # Drop a name. Master only.
    sub remove {
        my ( $self, $name ) = @_;

        Voxgig::Sekreto::checkname($name);
        my ( $vault, $opened ) = $self->load;
        my $root = $self->rootof( $opened, 'removing a secret' );

        my $wanted = Voxgig::Sekreto::Plugins::Minivault::entryid(
            Voxgig::Sekreto::Plugins::Minivault::secretkey( $root, $name ) );

        Voxgig::Sekreto::Plugins::Minivault::fail( 'no such secret: ' . $name )
          if !defined Voxgig::Sekreto::Plugins::Minivault::entryrecord( $vault, $wanted );

        $vault->{entries} = [ grep { $wanted ne $_->{id} } @{ $vault->{entries} } ];
        $self->save($vault);

        return;
    }

    # Every key in the file, with what it may do. Master only.
    sub keys {
        my ($self) = @_;
        my ( $vault, $opened ) = $self->load;
        $self->rootof( $opened, 'listing the keys' );

        my @out;

        for my $record ( @{ $vault->{keys} } ) {
            my $meta = $self->metaof( $opened, $record );

            my $id = $record->{id};

            if ( !defined $meta ) {
                push @out,
                  { key => $id, master => 0, write => 0, grants => [] };
            }
            else {
                push @out,
                  {
                    key    => $id,
                    master => $meta->{master} ? 1 : 0,
                    write  => $meta->{write}  ? 1 : 0,
                    grants => [ sort @{ $meta->{grants} || [] } ],
                  };
            }
        }

        return \@out;
    }

    # Mint a restricted key. Master only.
    sub grant {
        my ( $self, $spec ) = @_;

        my ( $vault, $opened ) = $self->load;
        my $root = $self->rootof( $opened, 'granting a key' );

        $spec ||= {};
        Voxgig::Sekreto::Plugins::Minivault::checkid( $spec->{key},
            'a grant needs a key id' );


        Voxgig::Sekreto::Plugins::Minivault::fail('a grant needs a passphrase')
          if !defined $spec->{passphrase}
          || ref( $spec->{passphrase} )
          || '' eq $spec->{passphrase};

        Voxgig::Sekreto::Plugins::Minivault::fail( 'key already exists: ' . $spec->{key} )
          if defined Voxgig::Sekreto::Plugins::Minivault::keyrecord( $vault, $spec->{key} );

        my @names = sort @{ $spec->{names} || [] };
        my %grants;

        for my $name (@names) {
            Voxgig::Sekreto::checkname($name);
            $grants{$name} = Voxgig::Sekreto::Plugins::Minivault::b64(
                Voxgig::Sekreto::Plugins::Minivault::secretkey( $root, $name ) );
        }

        my $write = ( defined $spec->{write} && $spec->{write} ) ? 1 : 0;

        push @{ $vault->{keys} },
          Voxgig::Sekreto::Plugins::Minivault::sealkey(
            $root,
            $spec->{key},
            $spec->{passphrase},
            $spec->{iterations} || $self->{iterations},

            # GRANTS IS ALWAYS THERE, even granted nothing. A ring without
            # it is a MASTER's ring in every port's reader, so dropping the
            # empty map would be a key that reads the whole vault.
            {
                v      => Voxgig::Sekreto::Plugins::Minivault::FORMAT(),
                write  => $write ? JSON::PP::true : JSON::PP::false,
                grants => \%grants,
            },
            {
                v      => Voxgig::Sekreto::Plugins::Minivault::FORMAT(),
                master => JSON::PP::false,
                write  => $write ? JSON::PP::true : JSON::PP::false,
                grants => \@names,
            }
          );

        $self->save($vault);

        return;
    }

    # Drop a key. Master only.
    #
    # Anyone who already copied the file keeps whatever that key could
    # read, so revoking bars future reads of the LIVE file and `rotate` is
    # what takes a secret back.
    sub revoke {
        my ( $self, $key ) = @_;

        my ( $vault, $opened ) = $self->load;
        $self->rootof( $opened, 'revoking a key' );

        Voxgig::Sekreto::Plugins::Minivault::fail( 'a key cannot revoke itself: ' . $key )
          if $key eq $opened->{info}{key};

        Voxgig::Sekreto::Plugins::Minivault::fail( 'no such key: ' . $key )
          if !defined Voxgig::Sekreto::Plugins::Minivault::keyrecord( $vault, $key );

        $vault->{keys} = [ grep { $key ne $_->{id} } @{ $vault->{keys} } ];
        $self->save($vault);

        return;
    }

    # A new root key, every value re-encrypted under it, and EVERY OTHER
    # KEY DROPPED. Master only.
    #
    # The other keys go because they must: their rings are sealed under
    # passphrases this process does not have. Re-grant afterwards.
    sub rotate {
        my ($self) = @_;

        my ( $vault, $opened ) = $self->load;
        $self->rootof( $opened, 'rotating the vault' );

        # Read everything out under the old root before anything changes:
        # once the root is replaced the old derived keys are unreachable.
        my @plain = map { [ $_, $self->get($_) ] } @{ $self->list };

        my $root = Voxgig::Sekreto::Plugins::Minivault::randombytes(
            Voxgig::Sekreto::Plugins::Minivault::KEYLEN() );
        my $namekey = Voxgig::Sekreto::Plugins::Minivault::mac( $root,
            Voxgig::Sekreto::Plugins::Minivault::LABEL_NAMES() );

        my @entries;

        for my $pair (@plain) {
            my ( $name, $value ) = @{$pair};
            my $key = Voxgig::Sekreto::Plugins::Minivault::secretkey( $root, $name );

            push @entries,
              {
                id   => Voxgig::Sekreto::Plugins::Minivault::entryid($key),
                name => Voxgig::Sekreto::Plugins::Minivault::seal(
                    $namekey, $name, Voxgig::Sekreto::Plugins::Minivault::AAD_NAME()
                ),
                value => Voxgig::Sekreto::Plugins::Minivault::seal(
                    $key, $value,
                    Voxgig::Sekreto::Plugins::Minivault::AAD_SECRET() . $name
                ),
              };
        }

        my $record =
          Voxgig::Sekreto::Plugins::Minivault::keyrecord( $vault, $self->{keyid} );

        my $fresh = Voxgig::Sekreto::Plugins::Minivault::sealkey(
            $root, $self->{keyid}, $self->{passphrase}, $record->{iters},
            {
                v     => Voxgig::Sekreto::Plugins::Minivault::FORMAT(),
                write => JSON::PP::true,
                root  => Voxgig::Sekreto::Plugins::Minivault::b64($root),
            },
            {
                v      => Voxgig::Sekreto::Plugins::Minivault::FORMAT(),
                master => JSON::PP::true,
                write  => JSON::PP::true,
                grants => [],
            }
        );

        # SAVE FIRST, adopt second. A handle holding the new root over a
        # file that still holds the old one reads nothing and says the
        # vault is damaged, which is the wrong story about a failed write.
        $self->save( { keys => [$fresh], entries => \@entries } );

        $self->{opened} = {
            info => {
                key    => $self->{keyid},
                master => 1,
                write  => 1,
                grants => [],
            },
            root   => $root,
            grants => {},
            ring   => $fresh->{ring},
        };

        return;
    }

    # ------------------------------------------------------------ inside

    sub bytes {
        my ($self) = @_;

        my $raw = Voxgig::Sekreto::Plugins::Minivault::readmaybe( $self->{file} );
        return $raw if defined $raw;

        # A vault is configured deliberately, with a key. Its absence is a
        # broken deployment and never "no secrets here": answering a miss
        # would send the chain on to a weaker store.
        Voxgig::Sekreto::Plugins::Minivault::fail( 'no vault file: ' . $self->{file} )
          if !$self->{create};

        Voxgig::Sekreto::Plugins::Minivault::putnew(
            $self->{file},
            Voxgig::Sekreto::Plugins::Minivault::newvault(
                $self->{keyid}, $self->{passphrase}, $self->{iterations}
            )
        );

        $raw = Voxgig::Sekreto::Plugins::Minivault::readmaybe( $self->{file} );
        Voxgig::Sekreto::Plugins::Minivault::fail( 'cannot read ' . $self->{file} )
          if !defined $raw;

        return $raw;
    }

    sub load {
        my ($self) = @_;

        my $vault = Voxgig::Sekreto::Plugins::Minivault::readfile( $self->bytes );
        my $record =
          Voxgig::Sekreto::Plugins::Minivault::keyrecord( $vault, $self->{keyid} );

        if ( !defined $record ) {
            # REVOKED, or never there. Either way this handle is finished,
            # and dropping what it derived is what stops the next call
            # answering from memory.
            $self->{opened} = undef;
            Voxgig::Sekreto::Plugins::Minivault::fail( 'no such key: ' . $self->{keyid} );
        }

        # The file still holds this key, and holds the SAME ring: a key
        # revoked and re-granted under another passphrase is a different
        # key wearing the id, and re-deriving is what refuses it.
        return ( $vault, $self->{opened} )
          if defined $self->{opened}
          && Voxgig::Sekreto::Plugins::Minivault::sameseal( $self->{opened}{ring},
            $record->{ring} );

        $self->{opened} = undef;

        my $plain = Voxgig::Sekreto::Plugins::Minivault::unseal(
            Voxgig::Sekreto::Plugins::Minivault::kek(
                $self->{passphrase}, $record->{salt}, $record->{iters}
            ),
            $record->{ring},
            Voxgig::Sekreto::Plugins::Minivault::AAD_RING() . $self->{keyid},
            'wrong passphrase for key ' . $self->{keyid} . ', or a damaged vault'
        );

        my $ring = Voxgig::Sekreto::Plugins::Minivault::parsejson( $plain,
            'key ring for ' . $self->{keyid} );

        my %grants;
        my $held = $ring->{grants} || {};

        for my $name ( CORE::keys %{$held} ) {
            $grants{$name} =
              Voxgig::Sekreto::Plugins::Minivault::unb64( $held->{$name}, 'a granted key' );
        }

        my $root = $ring->{root};

        $self->{opened} = {
            info => {
                key    => $self->{keyid},
                master => defined $root ? 1 : 0,
                write  => ( defined $root || $ring->{write} ) ? 1 : 0,
                grants => [ sort CORE::keys %grants ],
            },
            root => defined $root
            ? Voxgig::Sekreto::Plugins::Minivault::unb64( $root, 'the root key' )
            : undef,
            grants => \%grants,
            ring   => $record->{ring},
        };

        return ( $vault, $self->{opened} );
    }

    sub rootof {
        my ( $self, $opened, $what ) = @_;

        Voxgig::Sekreto::Plugins::Minivault::fail( $what
              . ' needs a master key, and '
              . $opened->{info}{key}
              . ' is restricted' )
          if !defined $opened->{root};

        return $opened->{root};
    }

    # The key for one name, or undef when this key cannot reach it.
    sub keyfor {
        my ( $self, $opened, $name ) = @_;

        return Voxgig::Sekreto::Plugins::Minivault::secretkey( $opened->{root}, $name )
          if defined $opened->{root};

        return $opened->{grants}{$name};
    }

    sub findentry {
        my ( $self, $vault, $key ) = @_;

        return undef if !defined $key;

        return Voxgig::Sekreto::Plugins::Minivault::entryrecord( $vault,
            Voxgig::Sekreto::Plugins::Minivault::entryid($key) );
    }

    sub metaof {
        my ( $self, $opened, $record ) = @_;

        my $root = $self->rootof( $opened, 'reading key metadata' );
        my $what = 'metadata for key ' . $record->{id};

        my $meta;
        my $ok = eval {
            $meta = Voxgig::Sekreto::Plugins::Minivault::parsejson(
                Voxgig::Sekreto::Plugins::Minivault::unseal(
                    Voxgig::Sekreto::Plugins::Minivault::mac(
                        $root, Voxgig::Sekreto::Plugins::Minivault::LABEL_META()
                    ),
                    $record->{meta},
                    Voxgig::Sekreto::Plugins::Minivault::AAD_META() . $record->{id},
                    $what
                ),
                $what
            );
            1;
        };

        # A record written under a root key this one has replaced. The key
        # is still in the file and still opens with its own passphrase, so
        # it is reported rather than hidden - with what it can do unknown.
        return undef if !$ok;

        return $meta;
    }

    # Read, change, and REPLACE - never edit in place.
    #
    # THE TEMPORARY IS RANDOM AND EXCLUSIVE. `<vault>.<pid>.tmp` is a name
    # anyone can predict, so anyone who can write the vault's directory
    # could put a symlink there and have the next save truncate whatever
    # it pointed at.
    sub save {
        my ( $self, $vault ) = @_;

        my $temp = $self->{file} . '.'
          . unpack( 'H*', Voxgig::Sekreto::Plugins::Minivault::randombytes(8) ) . '.tmp';

        my $why = Voxgig::Sekreto::Plugins::Minivault::spill( $temp,
            Voxgig::Sekreto::Plugins::Minivault::writefile($vault) );

        if ( !defined $why && !rename( $temp, $self->{file} ) ) {
            $why = "$!";
        }

        if ( defined $why ) {
            # The vault is unchanged either way, and the write error is
            # what the caller needs to be told about.
            unlink($temp);
            Voxgig::Sekreto::Plugins::Minivault::fail(
                'cannot write ' . $self->{file} . ': ' . $why );
        }

        return;
    }
}

# Open a vault file as one key.
#
# The handle is lazy. Nothing is read, and no passphrase is stretched,
# until a method needs the file.
sub openvault {
    return Voxgig::Sekreto::Plugins::Minivault::Vault->new( $_[0] );
}

# Make a vault file and return a handle on its master key.
#
# Refuses a file that is already there: a vault is created once, and
# overwriting one discards every secret in it.
sub createvault {
    my ($options) = @_;

    my $opts = $options || {};

    fail('a vault needs a file')
      if !defined $opts->{file} || ref( $opts->{file} ) || '' eq $opts->{file};

    fail('a vault needs a passphrase')
      if !defined $opts->{passphrase}
      || ref( $opts->{passphrase} )
      || '' eq $opts->{passphrase};

    my $keyid = checkid( wantkey( $opts->{key} ), 'a vault needs a key id' );

    # No existence check first: the check and the write would be two
    # steps, and `putnew` refuses an existing file in ONE.
    putnew( $opts->{file},
        newvault( $keyid, $opts->{passphrase}, $opts->{iterations} || ITERATIONS() ) );

    return openvault($opts);
}

# ------------------------------------------------------------ the provider

{
    # Read a vault as one store in a chain.
    #
    # The provider is the READ half and nothing more: a chain resolves
    # secrets, and writing one is a deliberate act with an API of its own.
    package Voxgig::Sekreto::Plugins::Minivault::Provider;

    use strict;
    use warnings;

    sub new {
        my ( $class, $vault ) = @_;
        return bless { vault => $vault }, $class;
    }

    sub lookup {
        my ( $self, $name ) = @_;
        return $self->{vault}->get($name);
    }

    sub describe {
        my ($self) = @_;
        return 'minivault:' . $self->{vault}->file;
    }
}

sub providerof {
    return Voxgig::Sekreto::Plugins::Minivault::Provider->new( $_[0] );
}

# A vault provider from options, for a chain built by hand.
sub minivaultprovider {
    return providerof( openvault( $_[0] ) );
}

# The vault options a provider spec describes.
sub minivaultoptions {
    my ($spec) = @_;

    return {
        file       => defined $spec->{file} ? $spec->{file} : '',
        key        => $spec->{vaultkey},
        passphrase => defined $spec->{passphrase} ? $spec->{passphrase} : '',
        iterations => $spec->{iterations},
        create     => ( defined $spec->{create} && $spec->{create} ) ? 1 : 0,
    };
}

# The vault behind a store in a chain, as its programmatic API.
#
# With no store named, the unqualified alias answers: one vault in the
# chain resolves whatever it is called, and two raise rather than picking
# one.
sub vaultof {
    my ( $secrets, $store ) = @_;

    if ( !defined $store ) {
        my $found = $secrets->host->exports( 'minivault/' . VAULT_EXPORT() );
        fail('no minivault store in this chain') if !defined $found;
        return $found;
    }

    # A NAMED STORE MUST EXIST, and the alias must not stand in for it.
    # `exports` falls back to the alias when the exact ref misses, so
    # asking for `minivault` in a chain whose only vault is named `app`
    # used to hand back the `app` vault - and then write to it. Naming a
    # store that is not there raises, which is the rule the whole library
    # follows: `try` already means "may not have it", so it cannot also
    # mean "may not exist".
    my $ref = 'minivault' eq $store ? 'minivault' : 'minivault$' . $store;

    fail( 'no minivault store named ' . $store . ' in this chain' )
      if !defined $secrets->host->instance($ref);

    return $secrets->host->exports( $ref . '/' . VAULT_EXPORT() );
}

# The plugin: the `minivault` provider kind, as a voxgig/plugin definition.
#
# Written out rather than built by `providerplugin`, because this
# definition publishes TWO exports: `provider`, the read half every kind
# publishes, and `vault`, the programmatic API.
sub minivault {
    return {
        name   => 'minivault',
        define => sub {
            my ($inst) = @_;

            my $options = minivaultoptions( $inst->options || {} );

            my $vault;

            # `openvault` refuses bad configuration HERE, so a mistyped
            # chain fails at construction. Reaching the FILE is not
            # configuration: the handle is lazy.
            my $ok = eval { $vault = openvault($options); 1 };

            if ( !$ok ) {
                my $err = $@;

                die $err
                  if !( Scalar::Util::blessed($err)
                    && $err->isa('Voxgig::Sekreto::SekretoError') );

                Voxgig::Plugin::Types::fail_with( ERROR_CODE(), "$err",
                    { ref => $inst->ref, cause => "$err" } );
            }

            $inst->export( PROVIDER_EXPORT(), providerof($vault) );
            $inst->export( VAULT_EXPORT(),    $vault );

            return;
        },
    };
}

1;
