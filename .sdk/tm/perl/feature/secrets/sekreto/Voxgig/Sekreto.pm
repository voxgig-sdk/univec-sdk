# VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (perl/lib/Voxgig/Sekreto.pm)
# Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
# License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
package Voxgig::Sekreto;

# sekreto: one interface for secrets, wherever they live.
#
# A Sekreto is an ordered chain of providers. `get` asks each in turn and
# returns the first hit, so an app can be configured from environment
# variables in development and a vault in production without changing a
# line of its own code.
#
# A port of typescript/src/Sekreto.ts, which is canonical.
#
# THE CORE LOADS NO PROVIDER THAT OPENS A SOCKET, SPAWNS A PROCESS OR SIGNS
# A REQUEST. The four built-in kinds - env, memory, dotenv, file - read at
# most a local file; every other kind is a voxgig/plugin definition under
# `plugins/`, and a chain may name one only if the calling project handed it
# in through `plugins`:
#
#     use Voxgig::Sekreto ();
#     use Voxgig::Sekreto::Plugins::Hashicorp qw(hashicorp);
#
#     my $secrets = Voxgig::Sekreto->new({
#         plugins   => [ hashicorp() ],
#         providers => [ { kind => 'env' }, { kind => 'hashicorp', addr => $addr } ],
#     });
#
# or, for every kind at once, `allplugins()` from Voxgig::Sekreto::Plugins.
# See docs/design/plugin-providers.md.

use strict;
use warnings;

use Exporter 'import';

use Scalar::Util ();

use Voxgig::Plugin qw(check_tag format_ref make_catalog make_host);

use Voxgig::Sekreto::Addr qw(checkaddr safeaddr);
use Voxgig::Sekreto::Providers qw(providerplugin);

our @EXPORT_OK = qw(
  awsparam checkaddr envkey flatname parsedotenv providerplugin redact safeaddr
  sekreto validname vaultref
);

our $VERSION = '0.1.0';

# Anything sekreto refuses to do: a bad name, a missing secret, a provider
# that could not be reached.
{

    package Voxgig::Sekreto::SekretoError;

    sub new {
        my ( $class, $message ) = @_;
        return bless { message => $message }, $class;
    }

    sub message { return $_[0]->{message} }

    use overload '""' => sub { $_[0]->{message} }, fallback => 1;
}

sub fail {
    my ($message) = @_;
    die Voxgig::Sekreto::SekretoError->new($message);
}

# Is this a well-formed secret name?
sub validname {
    my ($name) = @_;

    return 0 if !defined $name || ref($name);
    return 0 if '' eq $name;

    for my $part ( split( /\./, $name, -1 ) ) {
        # `\z`-style anchors, not `$`. In Python, PCRE, Perl and .NET `$` also
        # matches BEFORE a final newline, so `api.token\n` was accepted here while the
        # canonical port rejected it - and `envkey` then produced the key
        # `API_TOKEN\n`, sending this port looking for a differently named file and
        # variable than the others.
        return 0 if $part !~ /\A[a-z0-9_]+\z/;
    }

    return 1;
}

sub checkname {
    my ($name) = @_;

    fail( 'sekreto: invalid name: ' . ( defined $name && !ref($name) ? $name : '' ) )
      if !validname($name);

    return $name;
}

# The environment-variable key for a name: `api.token` -> `API_TOKEN`.
sub envkey {
    my ( $name, $prefix ) = @_;

    checkname($name);

    return ( defined $prefix ? $prefix : '' ) . uc( join( '_', split( /\./, $name, -1 ) ) );
}

# Where a name lives in a KV vault: `api.token` -> `api` / `token`.
#
# A single-segment name has no path of its own, so it becomes a secret of
# that name with the conventional field `value`.
sub vaultref {
    my ($name) = @_;

    checkname($name);

    my @parts = split( /\./, $name, -1 );

    return { path => $parts[0], field => 'value' } if 1 == scalar(@parts);

    my $field = pop @parts;

    return { path => join( '/', @parts ), field => $field };
}

# A name flattened to one segment: `api.token` -> `api_token` (GCP Secret
# Manager, `_`) or `api-token` (Azure Key Vault, `-`).
#
# Those stores have no path hierarchy and reject dots in ids, so the dots
# become the store's conventional separator. With `-` as the separator,
# underscores flatten too: Azure Key Vault's alphabet is letters, digits
# and hyphens only, and a valid sekreto name like `with_underscore` must
# still be representable there. (The resulting `.`/`_` collision mirrors
# the documented envkey behaviour, where both already map to `_`.)
sub flatname {
    my ( $name, $sep ) = @_;

    checkname($name);

    my $flat = join( $sep, split( /\./, $name, -1 ) );

    return '-' eq $sep ? join( '-', split( /_/, $flat, -1 ) ) : $flat;
}

# The AWS SSM Parameter Store name for a name: dots become the path
# hierarchy, rooted at `/` (or at a prefix): `db.pass.main` ->
# `/db/pass/main`, or `/app/db/pass/main` under prefix `/app`.
sub awsparam {
    my ( $name, $prefix ) = @_;

    checkname($name);

    my $base = defined $prefix ? $prefix : '';
    $base = '/' . $base if '' ne $base && 0 != index( $base, '/' );
    $base =~ s{/$}{};

    return $base . '/' . join( '/', split( /\./, $name, -1 ) );
}

# Parse `.env` text into a map of raw keys to values.
#
# Deliberately small: `KEY=value`, optional `export`, `#` comments on their
# own line, and single- or double-quoted values (double quotes also unescape
# \n, \r, \t and \\). A line with no `=` is skipped.
sub parsedotenv {
    my ($text) = @_;

    my %out;

    return \%out if !defined $text || ref($text);

    for my $rawline ( split( /\n/, $text, -1 ) ) {
        my $line = $rawline;
        $line =~ s/\r$//;
        $line =~ s/^\s+|\s+$//g;

        next if '' eq $line || 0 == index( $line, '#' );

        my $body = $line;
        if ( 0 == index( $line, 'export ' ) ) {
            $body = substr( $line, 7 );
            $body =~ s/^\s+|\s+$//g;
        }

        my $eq = index( $body, '=' );
        next if 0 >= $eq;

        my $key = substr( $body, 0, $eq );
        $key =~ s/^\s+|\s+$//g;

        my $value = substr( $body, $eq + 1 );
        $value =~ s/^\s+|\s+$//g;

        if ( 2 <= length($value) && '"' eq substr( $value, 0, 1 ) && '"' eq substr( $value, -1 ) ) {
            $value = unescape( substr( $value, 1, -1 ) );
        }
        elsif ( 2 <= length($value)
            && "'" eq substr( $value, 0, 1 )
            && "'" eq substr( $value, -1 ) )
        {
            $value = substr( $value, 1, -1 );
        }

        $out{$key} = $value;
    }

    return \%out;
}

sub unescape {
    my ($text) = @_;

    my $out   = '';
    my $index = 0;
    my $len   = length($text);

    while ( $index < $len ) {
        my $head = substr( $text, $index, 1 );

        if ( '\\' eq $head && $index + 1 < $len ) {
            my $next = substr( $text, $index + 1, 1 );
            $index += 2;

            if    ( 'n' eq $next )    { $out .= "\n" }
            elsif ( 'r' eq $next )    { $out .= "\r" }
            elsif ( 't' eq $next )    { $out .= "\t" }
            elsif ( '\\' eq $next )   { $out .= '\\' }
            elsif ( '"' eq $next )    { $out .= '"' }
            else                      { $out .= '\\' . $next }
        }
        else {
            $out .= $head;
            $index++;
        }
    }

    return $out;
}

# Replace known secret values in text with `[redacted]`.
#
# Only values of four characters or more are replaced: shorter ones are too
# likely to appear in ordinary text, and redacting them would make logs
# unreadable without making them safer.
sub redact {
    my ( $text, $values ) = @_;

    my $out = defined $text && !ref($text) ? $text : '';

    my @usable = grep { defined $_ && !ref($_) && 4 <= length($_) } @{ $values || [] };

    # Longest first: a shorter secret that prefixes a longer one used to eat
    # the prefix and leave the rest in the log. @usable is our own list, so
    # sorting it does not reorder the caller's.
    for my $value ( sort { length($b) <=> length($a) } @usable ) {
        $out = join( '[redacted]', split( /\Q$value\E/, $out, -1 ) );
    }

    return $out;
}

# The store name a provider handed in ALREADY BUILT answers to.
#
# `describe` opens with the provider's kind - `hashicorp:...`, `dotenv:...`,
# plain `env` - so the kind is the natural default, and a custom provider
# gets a sensible name without implementing anything extra. A spec'd
# provider never reaches here: its store is its `name` or its `kind`,
# decided by `declare` before the provider exists.
sub storename {
    my ($provider) = @_;

    return ( split( /:/, $provider->describe(), 2 ) )[0];
}

# The secrets facade: a chain of providers plus a cache.
#
# Two ways to read. `get` is transparent - it walks the chain and takes the
# first hit, and the caller never learns which store answered. `getfrom` is
# directed - it names the store, and only that store is asked.
sub new {
    my ( $class, $options ) = @_;

    my $opts = $options || {};

    # Built-ins first, then the plugins, into one catalog: a plugin that
    # names a built-in kind replaces it, which is how a host substitutes an
    # implementation and never an accident, because the four names are
    # documented.
    #
    # `catalog` is the definitions this Sekreto can build; `host` is the
    # voxgig/plugin host every spec'd provider is an instance of.
    my $catalog = make_catalog(
        [
            @{ Voxgig::Sekreto::Providers::builtins() },
            map { definition($_) } @{ $opts->{plugins} || [] }
        ]
    );

    my $self = {
        catalog => $catalog,
        host    => make_host( { catalog => $catalog } ),

        # (store, provider) pairs, in chain order. A provider handed in
        # live is backed by no instance; a spec'd one is an instance of its
        # kind on the host.
        entries => [],
        docache => ( exists $opts->{cache} && !$opts->{cache} ) ? 0 : 1,

        # A list, not a hash: the store a value came from stays attached,
        # and redaction order does not vary between runs.
        cache => [],

        # Every value ever resolved, for redactall. Kept independently of
        # the read cache so that redaction still works when cache is off -
        # otherwise `cache => 0` would silently disable redactall and leak
        # secrets to logs.
        seen => [],
    };

    bless $self, $class;

    for my $entry ( @{ $opts->{providers} || [] } ) {
        if ( 'HASH' eq ( ref($entry) || '' ) ) {
            push @{ $self->{entries} }, $self->declare($entry);
        }
        else {
            push @{ $self->{entries} }, [ storename($entry), $entry ];
        }
    }

    return $self;
}

# The voxgig/plugin host every spec'd provider is an instance of, and the
# catalog of definitions this Sekreto can build from. For introspection -
# `$secrets->host->list` names each store's ref and status - and nothing on
# either advances the chain.
sub host    { return $_[0]->{host} }
sub catalog { return $_[0]->{catalog} }

# One chain entry, as a plugin instance.
#
# The instance is `kind` for a store named after its kind and `kind$store`
# otherwise - `hashicorp$prod` - so `host->list` reads like the chain. A
# store name that is already taken gets a numbered tag from the host
# instead, because two providers MAY share a store name (a directed read
# walks both) and an instance ref may not.
sub declare {
    my ( $self, $spec ) = @_;

    my $kind = $spec->{kind};

    fail( unknownkind( $kind, $self->{catalog} ) )
      if !defined $kind || ref($kind) || !$self->{catalog}->has($kind);

    my $store = $spec->{name} || $kind;

    fail( 'sekreto: invalid store name: ' . ( ref($store) ? '' : $store ) )
      if !check_tag($store);

    my $ref = $store eq $kind ? $kind : format_ref( $kind, $store );
    $ref = $self->{host}->autotag($kind) if defined $self->{host}->instance($ref);

    # `load` runs the definition's `define`, which builds the provider from
    # the spec; `activate` takes the instance live. Nothing is contacted by
    # either: a provider opens nothing until its first lookup.
    my $ok = eval {
        $self->{host}->load( $ref, { options => $spec } );
        $self->{host}->activate($ref);
        1;
    };
    die unwrap($@) if !$ok;

    return [
        $store,
        $self->{host}->exports(
            $ref . '/' . Voxgig::Sekreto::Providers::PROVIDER_EXPORT()
        )
    ];
}

# A plugin entry, checked to be a definition before the catalog sees it.
#
# A definition is a hashref, and a plugin module hands one back from a sub
# named after the kind. The two ways to get that wrong in perl are to pass
# the module name and to pass the sub without calling it, so both are
# refused here, naming the call that was meant - rather than failing deep
# inside voxgig/plugin with a message about a definition name.
sub definition {
    my ($plugin) = @_;

    return $plugin if 'HASH' eq ( ref($plugin) || '' );

    if ( defined $plugin && !ref($plugin) && $plugin =~ /::/ ) {
        my $kind = lc( ( split( /::/, $plugin ) )[-1] );
        fail(   'sekreto: not a plugin definition: the module ' 
              . $plugin
              . ' - call the definition it holds: use '
              . $plugin . ' qw('
              . $kind . '); '
              . $kind
              . '()' );
    }

    fail( 'sekreto: not a plugin definition: a code reference'
          . ' - a definition is what calling it returns' )
      if 'CODE' eq ( ref($plugin) || '' );

    fail( 'sekreto: not a plugin definition: '
          . ( !defined $plugin ? '' : ref($plugin) ? ref($plugin) : $plugin ) );
}

# The message for a kind the catalog does not hold.
#
# A kind sekreto has never heard of is a typo; a kind that exists as a
# plugin but was not passed in is the split working as designed and telling
# you what to pass. Collapsing the two was the first thing that made the
# split confusing to use.
sub unknownkind {
    my ( $kind, $catalog ) = @_;

    my $shown = ( defined $kind && !ref($kind) ) ? $kind : '';

    my $message =
        'sekreto: unknown provider kind: ' 
      . $shown
      . ' (available: '
      . join( ', ', @{ $catalog->names } ) . ')';

    $message .= ' - ' 
      . $shown
      . ' is a sekreto plugin, not built in: pass it in the plugins option'
      if grep { $_ eq $shown } @{ Voxgig::Sekreto::Providers::kinds()->{plugin} };

    return $message;
}

# A SekretoError that crossed the plugin boundary comes back out as itself,
# byte for byte. Anything else is not sekreto's to rewrite.
sub unwrap {
    my ($err) = @_;

    return $err if !Scalar::Util::blessed($err) || !$err->can('code');

    my $code = eval { $err->code };
    return $err
      if !defined $code || Voxgig::Sekreto::Providers::ERROR_CODE() ne $code;

    my $details = $err->{details};
    return $err
      if 'HASH' ne ( ref($details) || '' )
      || !defined $details->{cause}
      || ref( $details->{cause} );

    return Voxgig::Sekreto::SekretoError->new( $details->{cause} );
}

# The secret, or a SekretoError if no provider has it.
sub get {
    my ( $self, $name ) = @_;

    my $found = $self->try($name);

    fail( 'sekreto: unknown secret: ' . $name ) if !defined $found;

    return $found;
}

# The secret, or undef if no provider has it.
sub try {
    my ( $self, $name ) = @_;
    return $self->_resolve( '', $name, $self->{entries} );
}

# The secret from one named store, or a SekretoError if that store does not
# have it.
sub getfrom {
    my ( $self, $store, $name ) = @_;

    my $found = $self->tryfrom( $store, $name );

    fail( 'sekreto: unknown secret: ' . $store . ':' . $name ) if !defined $found;

    return $found;
}

# The secret from one named store, or undef if that store does not have it.
#
# Naming a store that is not in the chain is an error, not a miss: `try`
# already means "this store may not have it", so it cannot also mean "this
# store may not exist" without hiding a typo.
sub tryfrom {
    my ( $self, $store, $name ) = @_;

    my @matching = grep { $_->[0] eq $store } @{ $self->{entries} };

    fail( 'sekreto: unknown store: ' . $store ) if 0 == scalar(@matching);

    return $self->_resolve( $store, $name, \@matching );
}

sub _resolve {
    my ( $self, $store, $name, $entries ) = @_;

    checkname($name);

    if ( $self->{docache} ) {
        for my $cached ( @{ $self->{cache} } ) {
            return $cached->[2] if $cached->[0] eq $store && $cached->[1] eq $name;
        }
    }

    for my $entry ( @{$entries} ) {
        my $found = $entry->[1]->lookup($name);

        if ( defined $found ) {
            push @{ $self->{cache} }, [ $store, $name, $found ] if $self->{docache};
            push @{ $self->{seen} }, $found;
            return $found;
        }
    }

    return undef;
}

# Does any provider have this secret?
sub has {
    my ( $self, $name ) = @_;
    return defined $self->try($name) ? 1 : 0;
}

# Does this named store have this secret?
sub hasin {
    my ( $self, $store, $name ) = @_;
    return defined $self->tryfrom( $store, $name ) ? 1 : 0;
}

# Every named secret at once. Missing ones are an error.
sub all {
    my ( $self, $names ) = @_;

    my %out;
    $out{$_} = $self->get($_) for @{$names};

    return \%out;
}

# A description of each provider, in resolution order.
sub sources {
    my ($self) = @_;
    return [ map { $_->[1]->describe() } @{ $self->{entries} } ];
}

# The name of each store that can be named by `getfrom`, in resolution order
# and without repeats.
sub stores {
    my ($self) = @_;

    my ( @out, %seen );
    for my $entry ( @{ $self->{entries} } ) {
        push @out, $entry->[0] if !$seen{ $entry->[0] }++;
    }

    return \@out;
}

# Replace every value this Sekreto has resolved with `[redacted]`.
#
# Works whether or not caching is enabled: the redaction list is kept
# independently of the read cache.
sub redactall {
    my ( $self, $text ) = @_;
    return redact( $text, $self->{seen} );
}

# Drop cached values, so the next `get` asks the providers again.
sub refresh {
    my ($self) = @_;
    $self->{cache} = [];
    return;
}

# Tear the chain down: every plugin instance is deactivated and unloaded,
# in reverse, releasing whatever a provider acquired at activation.
# Afterwards there is nothing to read from - `get` reports every secret
# unknown - and the cache is dropped, though `redactall` still knows every
# value that was ever resolved.
sub close {
    my ($self) = @_;

    $self->{host}->close;
    $self->{entries} = [];
    $self->{cache}   = [];

    return;
}

# Make a Sekreto from options.
sub sekreto {
    my ($options) = @_;
    return Voxgig::Sekreto->new($options);
}

1;
