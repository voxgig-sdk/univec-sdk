# Univec SDK secrets feature
#
# Secret access via a vendored @voxgig/sekreto provider chain, and the
# access-token exchange some APIs require on top of it. The perl port of
# tm/ts/src/feature/secrets/SecretsFeature.ts - same contract, perl idiom,
# and the GO port's structure (see THE TRANSPORT SEAM below).
#
# The SDK's `apikey` option keeps exactly its old meaning: an explicit
# credential given in code. This feature makes it ONE SOURCE among several
# rather than the only one: when active, the apikey is resolved through a
# sekreto chain in which the explicit option (when set) is the FIRST
# provider - a `memory` store named `options` - so an explicit value always
# wins, by sekreto's own first-hit rule rather than by special-case logic.
# When the option is unset, the remaining providers (env, dotenv, a vault)
# are asked in order, and moving a credential from code to a vault becomes
# a configuration change.
#
# MISS vs ERROR (sekreto's invariant): a provider MISS falls through - the
# op proceeds, unauthenticated if nothing else supplies a credential. A
# provider ERROR (unreachable vault, bad creds) must FAIL the op: a broken
# vault never degrades into an unauthenticated request. Voxgig::Sekreto
# spells that difference exactly - `try` returns undef on a miss and DIES
# on a provider error - so the rule is inherited rather than reimplemented.
#
# THE TRANSPORT SEAM, and why this port follows go rather than ts.
#
# UnivecSDK::prepare() runs NO feature hooks - it calls prepare_auth
# directly - and _raw_request (which BOTH direct() and graphql() funnel
# through) reaches the wire through it. A feature that resolved only in
# PreSpec would leave those two paths unauthenticated and never notice,
# which is why the py port had to bolt an explicit resolve seam into its
# generated client. perl needs none: entity ops (utility/make_request.pm),
# direct() and graphql() all call `$utility->{fetcher}` on contexts that
# INHERIT the one utility object this feature wraps in init - so wrapping
# the fetcher covers every wire path at once, with no edit to the
# generated client.
#
# So the resolved credential lives in FEATURE STATE (`cred`) and the
# Authorization header is rewritten HERE, at the seam, the same way
# prepare_auth builds it (utility/prepare_auth.pm) and honouring the same
# `auth => undef` suppression. The shared options map is never written.
#
# EXCHANGE: some APIs will not take a long-lived credential at all. What
# the chain resolves is then a REFRESH token, which buys a short-lived
# ACCESS token from a token endpoint (`exchange.path`, relative to
# options.base); the access token is what every request carries, and when
# a response status in `exchange.statuses` (401) says it is spent the
# wrapper buys another and retries the same request once. Test mode buys
# nothing and answers with a deterministic fake token.

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;

BEGIN {
  $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__));

  # The vendored sekreto and plugin ports keep their UPSTREAM package
  # layout (Voxgig/Sekreto.pm, Voxgig/Plugin/*.pm,
  # Voxgig/Sekreto/Plugins/*.pm), so they resolve through @INC rather than
  # a file-path require - the same convention t/omni.pm uses for the
  # vendored omni port. `plugins` is on the path even when no plugin group
  # is selected: the roots cost nothing, and a group added later needs no
  # edit here.
  unshift @INC,
    "$__dir/secrets/sekreto",
    "$__dir/secrets/plugin",
    "$__dir/secrets/plugins";
}

require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

use Voxgig::Sekreto ();

package UnivecSecretsFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.1.0';
  $self->{name} = 'secrets';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};

  # The LIVE options map (root ctx options, which IS the client's options
  # hash). Read for `auth` and the explicit apikey; never written.
  $self->{liveopts} = {};

  $self->{secretname} = 'apikey';
  $self->{cache} = 1;
  $self->{sek} = undef;

  # The RESOLVED credential, held in feature state and injected into each
  # request at the transport seam.
  $self->{cred} = '';
  $self->{resolved} = 0;

  # Exchange state: undef config when off, the refresh credential the
  # chain resolved, and the access token bought with it.
  $self->{exchange} = undef;
  $self->{refresh} = '';

  # A configuration error that init could not raise (an unknown provider
  # kind, a provider given in a shape this port cannot carry). Held rather
  # than thrown so the transport gate refuses to send: a misconfigured
  # chain is fail-closed, never silently unauthenticated.
  $self->{initerr} = undef;

  return $self;
}


# Sync by contract (init cannot do IO on the caller's behalf): build the
# chain only, never look anything up here.
sub init {
  my ($self, $ctx, $options) = @_;

  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  $self->{liveopts} = Voxgig::Struct::ismap($ctx->{options}) ? $ctx->{options} : {};

  return unless $self->{active};

  # THE CHAIN IS BUILT FIRST AND THE TRANSPORT IS WRAPPED UNCONDITIONALLY.
  #
  # _build returns a configuration error rather than raising one, and the
  # wrap below happens EVEN THEN. That ordering is the whole fail-closed
  # guarantee: a chain that could not be built - an unknown provider kind,
  # a provider in a shape this port cannot carry - must make every request
  # REFUSE, not sail past an unwrapped transport unauthenticated. Bailing
  # out of init early was exactly that bug, and it looked like a tidy
  # guard clause.
  $self->{initerr} = $self->_build($ctx);

  # The seam the public secrets() accessor reads.
  $self->{client}{_secrets} = $self;

  # WRAP THE TRANSPORT. The fail-closed gate needs the seam whenever the
  # feature is active, and the exchange (when on) additionally needs to
  # SEE responses - expiry is only ever discovered from one, and this is
  # the one place a response can be seen and the request tried again.
  my $feature = $self;
  my $utility = $ctx->{utility};
  my $inner = $utility->{fetcher};

  $utility->{fetcher} = sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    return $feature->transport($fctx, $fullurl, $fetchdef, $inner);
  };

  return;
}


# Build the provider chain. Returns a configuration-error MESSAGE, or
# undef. Never raises: init's caller is the SDK constructor, and a client
# that refuses every request says more than one that failed to exist.
sub _build {
  my ($self, $ctx) = @_;

  my $o = $self->{options};

  my $name = $o->{name};
  $self->{secretname} =
    (defined $name && !ref $name && '' ne $name) ? $name : 'apikey';

  $self->{cache} = UnivecHelpers::is_false($o->{cache}) ? 0 : 1;

  # Exchange config, normalised once. undef when off, so every later
  # decision is a defined check rather than a repeated `active` test.
  my $xopts = UnivecHelpers::to_map($o->{exchange});
  if ($xopts && UnivecHelpers::is_true($xopts->{active})) {
    my @statuses;
    if (Voxgig::Struct::islist($xopts->{statuses})) {
      for my $s (@{ $xopts->{statuses} }) {
        my $i = UnivecHelpers::to_int($s);
        push @statuses, $i if 0 <= $i;
      }
    }
    @statuses = (401) unless @statuses;

    $self->{exchange} = {
      'path' => _str($xopts->{path}, 'auth/token'),
      'method' => _str($xopts->{method}, 'POST'),
      'request' => _str($xopts->{request}, 'refresh_token'),
      'response' => _str($xopts->{response}, 'access_token'),
      'statuses' => \@statuses,
      'retries' => (defined $xopts->{retries}
        ? UnivecHelpers::to_int($xopts->{retries}) : 1),
    };
    $self->{exchange}{retries} = 1 if 0 > $self->{exchange}{retries};
  }

  # The explicit credential, when set, is the first store in the chain.
  #
  # WHICH option that is depends on the exchange. Without one, the secret
  # being resolved IS the credential the transport sends, so `apikey` is
  # it. With one, the secret is a REFRESH token and `apikey` means the
  # opposite thing - an access token the caller already holds - so the
  # explicit seat belongs to `exchange.refresh`, and apikey is left alone
  # to serve as the starting access token (see _resolve_once).
  my $explicit = !defined $self->{exchange}
    ? UnivecHelpers::gp($self->{liveopts}, 'apikey')
    : ($xopts ? $xopts->{refresh} : undef);
  $explicit = '' unless defined $explicit && !ref $explicit;

  my @providers;

  if ('' ne $explicit) {
    my $key = eval { Voxgig::Sekreto::envkey($self->{secretname}, '') };
    return _trim("$@") if !defined $key;
    push @providers, {
      'kind' => 'memory',
      'name' => 'options',
      'values' => { $key => "$explicit" },
    };
  }

  my $given = $o->{providers};
  if (Voxgig::Struct::islist($given)) {
    my $i = -1;
    for my $p (@$given) {
      $i++;
      my ($entry, $err) = $self->_provider($p, $i);
      return $err if defined $err;
      push @providers, $entry;
    }
  }

  # The plugin DEFINITIONS the model selected for this feature, emitted by
  # Config from the catalogue's active `plugin.def` entries. Upstream
  # sekreto's contract since the registry was retired: a kind not passed
  # in `plugins` is unknown to this Sekreto, so the model's choice of
  # plugin groups IS the SDK's provider vocabulary.
  #
  # Read through `can` at INIT time, not at load time: config.pm is
  # required before features.pm, but a project whose model selects no
  # plugin group gets a config.pm with no such sub at all, and that is a
  # supported shape rather than an error.
  my $plugins = [];
  if (UnivecConfig->can('feature_plugins')) {
    my $got = UnivecConfig::feature_plugins($self->{name});
    $plugins = $got if Voxgig::Struct::islist($got);
  }

  my $sek = eval {
    Voxgig::Sekreto->new({
      'providers' => \@providers,
      'plugins' => $plugins,
      'cache' => $self->{cache},
    });
  };

  # An unknown provider kind is refused HERE, at construction. init
  # cannot fail the client the way the ts reference's throwing
  # constructor does, so the transport gate refuses to send instead -
  # fail-closed, not silently unauthenticated.
  return _trim("$@") if !defined $sek;

  $self->{sek} = $sek;

  return undef;
}


# The LIVE Sekreto instance, for the SDK's secrets() accessor and for
# callers who want arbitrary secrets or redaction:
#
#   $sdk->secrets->get('db.password')
#   $sdk->secrets->redactall($logline)
#
# Never a clone: sekreto holds provider state (caches, vault leases) that
# has to stay live to be worth anything.
sub sekreto {
  my ($self) = @_;
  return $self->{sek};
}


# The resolved credential (empty when none) - the state the transport
# injects. Tests and callers read it here rather than from the options
# map, which this feature never mutates.
sub credential {
  my ($self) = @_;
  return $self->{cred};
}


# transport wraps whatever transport was current at init.
sub transport {
  my ($self, $ctx, $url, $fetchdef, $inner) = @_;

  # FAIL-CLOSED, at the ONE seam every wire path crosses. Entity ops,
  # direct(), graphql() and the exchange retries all come through this
  # wrapper, so resolving HERE is what gives the raw paths - which run no
  # feature hooks at all - the same credential the entity pipeline gets. A
  # provider ERROR refuses the request with the provider's own message;
  # never an unauthenticated send.
  my $err = $self->resolve();
  if (defined $err) {
    return (undef, $ctx->make_error('secrets_resolve', $err));
  }

  # Inject the resolved credential into THIS request's header. The header
  # was built by prepare_auth from the options apikey; the chain-resolved
  # value lives in feature state instead, so the wrapper writes it here -
  # same construction, same suppression rules.
  $self->_reauth($fetchdef, $self->{cred}) if '' ne $self->{cred};

  return $inner->($ctx, $url, $fetchdef) if !defined $self->{exchange};

  return $self->_with_refresh($ctx, $url, $fetchdef, $inner);
}


# One resolution, shared by every request. A settled HIT is kept only when
# caching is on (`cache: false` means every resolve asks the chain again);
# a FAILURE is never kept, so a transient vault outage cannot poison the
# client permanently - the next request asks the chain again.
#
# A MISS is not kept either, however caching is set. That rule is
# sekreto's, not this feature's: `A miss is never cached: the next read
# asks again`, in sekreto's own source. Keeping a settled miss here would
# override that from the layer above, and a secret provisioned after
# startup - a mounted file, a policy granted a minute late - would never be
# picked up for the life of the client. `cache` is about caching a HIT; it
# was never a promise to keep saying no.
#
# Returns an error MESSAGE (a string) or undef.
sub resolve {
  my ($self) = @_;

  return $self->{initerr} if defined $self->{initerr};
  return undef if $self->{resolved} && $self->{cache};

  my ($err, $hit) = $self->_resolve_once();
  $self->{resolved} = (defined($err) || !$hit) ? 0 : 1;

  return $err;
}


# Resolve once, answering ($err, $hit): whether a credential came out of
# it. That flag is the whole of what resolve needs to tell a cacheable HIT
# from a miss it must not keep.
sub _resolve_once {
  my ($self) = @_;

  return (undef, 0) unless defined $self->{sek};

  # sekreto's miss-vs-error rule, inherited: `try` returns undef on a MISS
  # and dies on a provider ERROR.
  my $found;
  my $ok = eval { $found = $self->{sek}->try($self->{secretname}); 1 };
  return (_trim(defined $@ && '' ne "$@" ? "$@" : 'secrets: provider failed'), 0)
    if !$ok;

  if (!defined $self->{exchange}) {
    # An UNCACHED miss after an earlier hit is a REVOCATION: the chain now
    # says no provider has the secret, so the resolved value must not keep
    # going out on the wire. (An explicit apikey OPTION is never lost this
    # way - it seats FIRST in the chain as a memory provider, so the chain
    # HITS while one is set and this branch is unreachable.)
    $self->{cred} = defined $found ? "$found" : '';
    return (undef, defined($found) ? 1 : 0);
  }

  # Exchanging: what the chain resolved is the REFRESH token, kept for
  # every later purchase. A miss is not fatal here - an explicit `apikey`
  # may already hold a usable access token, and the API is what gets to
  # say whether it does.
  $self->{refresh} = defined $found ? "$found" : '';

  if ('' eq $self->{cred}) {
    # A starting access token supplied as the OPTION.
    my $apikey = UnivecHelpers::gp($self->{liveopts}, 'apikey');
    $self->{cred} = (defined $apikey && !ref $apikey) ? "$apikey" : '';
  }

  # A starting access token was supplied. Spend it: if it is stale the API
  # answers with an expiry status and the wrapper buys another, which is
  # the same path expiry takes anyway.
  return (undef, 1) if '' ne $self->{cred};

  # `auth => undef` is the documented way to send NO credential, and a
  # purchase is a credential-bearing call: the refresh token goes to the
  # token endpoint in the request body. _with_refresh honours suppression
  # for the RETRY, but it runs after this - by then the refresh token has
  # already left the process, and no later check can call it back. The
  # suppression has to be honoured here, before the first purchase, or it
  # only ever half-held.
  return (undef, 0)
    if !defined UnivecHelpers::gp($self->{liveopts}, 'auth');

  my ($token, $err) = $self->_buy();
  return ($err, 0) if defined $err;

  $self->{cred} = $token;
  return (undef, 1);
}


# _with_refresh buys a token and tries the request again when the API says
# the current one is spent.
#
# The retry rewrites the authorization header IN PLACE on the fetchdef,
# because the header was built by the synchronous prepare_auth before this
# request left and it carries the token that just failed. Rebuilt the way
# prepare_auth builds it, from the same options auth.prefix, so the two
# cannot drift.
sub _with_refresh {
  my ($self, $ctx, $url, $fetchdef, $inner) = @_;

  # `auth => undef` is the documented way to send NO credential, and
  # prepare_auth honours it by removing the header. A refusal of a
  # deliberately unauthenticated request is not an expired token and
  # cannot be fixed by buying one - retrying would transmit exactly the
  # credential the caller suppressed.
  return $inner->($ctx, $url, $fetchdef)
    if !defined UnivecHelpers::gp($self->{liveopts}, 'auth');

  my $max = $self->{exchange}{retries};
  my $attempt = 0;

  while (1) {
    # The credential THIS attempt goes out with, captured before it
    # leaves: it is what tells a stale refusal apart from a fresh one.
    my $used = $self->{cred};

    my ($res, $err) = $inner->($ctx, $url, $fetchdef);

    return ($res, $err)
      if defined $err || $attempt >= $max || !$self->_spent($res);

    # Another request may have refreshed while this one was in flight.
    # Spend what is current before buying: a second exchange for a token
    # that is already fresh is wasted, and on a provider that invalidates
    # the previous credential on issuance it breaks the first request's
    # own retry.
    my $current = $self->{cred};
    my $token;

    if ('' ne $current && $current ne $used) {
      $token = $current;
    }
    else {
      my ($bought, $berr) = $self->_buy();
      if (defined $berr) {
        # The purchase failed: answer with the API's own refusal rather
        # than this one. The caller asked for data, and the refusal is the
        # more useful of the two - the exchange error is a symptom.
        return ($res, undef);
      }
      $token = $bought;
      $self->{cred} = $token;
    }

    $self->_reauth($fetchdef, $token);

    $attempt++;
  }
}


sub _spent {
  my ($self, $res) = @_;
  return 0 unless Voxgig::Struct::ismap($res);
  my $status = UnivecHelpers::to_int($res->{status});
  for my $s (@{ $self->{exchange}{statuses} }) {
    return 1 if $s == $status;
  }
  return 0;
}


sub _reauth {
  my ($self, $fetchdef, $token) = @_;

  return unless Voxgig::Struct::ismap($fetchdef);
  my $headers = $fetchdef->{headers};
  return unless Voxgig::Struct::ismap($headers);

  # Suppressed auth means NO header, the same answer prepare_auth gives
  # (utility/prepare_auth.pm). Reached defensively on the exchange path -
  # _with_refresh does not retry at all when auth is suppressed - but this
  # is the function that writes the credential, so it is where the rule
  # has to hold.
  if (!defined UnivecHelpers::gp($self->{liveopts}, 'auth')) {
    delete $headers->{'authorization'};
    return;
  }

  my $prefix = UnivecHelpers::gpath($self->{liveopts}, 'auth.prefix');
  $prefix = '' unless defined $prefix && !ref $prefix;

  # Empty prefix (raw apiKey credential) must not add a leading space.
  $headers->{'authorization'} = ('' eq $prefix) ? "$token" : "$prefix $token";

  return;
}


# Buy an access token with the refresh token. Returns (token, undef) or
# (undef, message).
sub _buy {
  my ($self) = @_;

  # TEST MODE BUYS NOTHING.
  #
  # The test feature replaces the transport so that no request leaves the
  # process; an exchange here would be the one HTTP call it could not
  # stop, and it would need a live token endpoint for a suite whose whole
  # point is not needing one. So test mode gets a deterministic,
  # obviously-fake token instead - the same answer make_options gives a
  # required server variable, for the same reason.
  my $mode = $self->{client}{mode};
  $mode = '' unless defined $mode;
  return ('test-' . $self->{exchange}{response}, undef) if 'live' ne $mode;

  return $self->_buy_once();
}


sub _buy_once {
  my ($self) = @_;
  my $x = $self->{exchange};

  return (undef,
    "secrets: no refresh token: the provider chain has no '"
      . $self->{secretname}
      . "', and feature.secrets.exchange.refresh is unset")
    if '' eq $self->{refresh};

  my $options = $self->{client}->options_map;

  # The token endpoint is RELATIVE to the base, which already carries
  # whatever account or tenant segment the server URL declares.
  my $base = UnivecHelpers::gp($options, 'base');
  $base = '' unless defined $base && !ref $base;
  $base =~ s{/+\z}{};
  my $path = $x->{path};
  $path =~ s{\A/+}{};
  my $url = "$base/$path";

  # Deliberately NOT the SDK transport. The transport is what this feature
  # wraps, and sending the token request back through it would recurse on
  # the first expiry - and would route the exchange through the test mock,
  # which knows nothing about it. `system.fetch` (the caller's own
  # transport seam) when supplied, else the raw HTTP fetch the utility
  # registry keeps beside its own fetcher.
  my $fetch = UnivecHelpers::gpath($options, 'system.fetch');
  if (!(defined $fetch && 'CODE' eq ref $fetch)) {
    # utility/fetcher.pm keeps the raw HTTP transport as a package global
    # BESIDE its registered fetcher, precisely so a caller that must not
    # recurse through the wrapper (or trip the test-mode block) can reach
    # it. `once` is disabled because this file names it exactly once.
    no warnings 'once';
    $fetch = $UnivecUtilities::DefaultHttpFetch;
  }

  return (undef, 'secrets: no fetch implementation for the token exchange')
    if !(defined $fetch && 'CODE' eq ref $fetch);

  # The body is MARSHALLED, never concatenated: a refresh token (or a
  # configured request-field name) carrying a quote, backslash or newline
  # must arrive as that literal value, not as malformed JSON.
  my $body = Voxgig::Struct::jsonify({ $x->{request} => $self->{refresh} });

  my ($res, $err);
  my $ok = eval {
    ($res, $err) = $fetch->($url, {
      'method' => $x->{method},
      'headers' => { 'content-type' => 'application/json' },
      'body' => $body,
    });
    1;
  };

  return (undef, _trim("$@")) if !$ok;

  return (undef, 'secrets: token exchange failed: ' . _trim("$err") . " from $url")
    if defined $err;

  my $status = Voxgig::Struct::ismap($res)
    ? UnivecHelpers::to_int($res->{status}) : 0;

  return (undef, "secrets: token exchange failed: $status from $url")
    if 200 > $status || 300 <= $status;

  my $data;
  my $jf = $res->{json};
  if ('CODE' eq (ref($jf) || '')) {
    $data = eval { $jf->() };
  }
  else {
    $data = $res->{body};
  }

  my $token = Voxgig::Struct::ismap($data) ? $data->{ $x->{response} } : undef;

  return (undef,
    "secrets: token exchange returned no '" . $x->{response} . "' field from $url")
    if !(defined $token && !ref $token && '' ne "$token");

  return ("$token", undef);
}


# One chain entry from a caller-supplied `providers` list.
#
# THE PERL SPELLING OF A CUSTOM PROVIDER IS A MAP OF CALLABLES:
#
#     providers => [ { lookup => sub { ... }, describe => sub { 'my:store' } } ]
#
# not a blessed object. make_options deep-clones the option tree
# (Voxgig::Struct::clone), which UNBLESSES objects while preserving
# coderefs, and it rescues only `system.fetch` and `extend` raw - so a
# blessed provider handed in here arrives at this feature as a plain hash
# with no methods at all. Rather than let that fail deep inside the plugin
# host with an unrelated message, the shape is checked and named here.
sub _provider {
  my ($self, $p, $i) = @_;

  # An object that really is a provider (constructed inside a subclassed
  # feature, say, where no cloning happened) joins the chain as it is.
  if (Scalar::Util::blessed($p)) {
    return ($p, undef) if $p->can('lookup') && $p->can('describe');
    return (undef, "secrets: provider $i: " . ref($p)
      . ' has no lookup/describe methods');
  }

  if (Voxgig::Struct::ismap($p)) {
    my $kind = $p->{kind};
    return ($p, undef) if defined $kind && !ref $kind && '' ne $kind;

    return (UnivecSecretsProvider->new($p), undef)
      if 'CODE' eq (ref($p->{lookup}) || '');

    return (undef, "secrets: provider $i: neither a { kind => ... } spec"
      . ' nor a { lookup => sub {...} } provider'
      . ' (a blessed provider object cannot survive option cloning in this'
      . ' port - pass a map of callables)');
  }

  return (undef, "secrets: provider $i: expected a map, got "
    . (ref($p) || (defined $p ? 'a scalar' : 'undef')));
}


sub _str {
  my ($v, $dflt) = @_;
  return (defined $v && !ref $v && '' ne $v) ? "$v" : $dflt;
}


sub _trim {
  my ($s) = @_;
  $s = '' unless defined $s;
  $s = "$s";
  $s =~ s/\s+\z//;
  return '' eq $s ? 'secrets: unknown error' : $s;
}


# The adapter that makes a map of callables a real sekreto provider.
package UnivecSecretsProvider;

sub new {
  my ($class, $map) = @_;
  return bless { map => $map }, $class;
}

sub lookup {
  my ($self, $name) = @_;
  return $self->{map}{lookup}->($name);
}

sub describe {
  my ($self) = @_;
  my $d = $self->{map}{describe};
  return 'CODE' eq (ref($d) || '') ? "" . $d->() : 'custom';
}

1;
