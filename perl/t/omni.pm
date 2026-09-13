# The corpus test runner: vendored Voxgig::Omni driven through its NATIVE
# API (`makeRunner(specref, provider)`), presented to the corpus tests in
# the struct-runner shape they already use (`$R->{spec}`, `$R->{runset}`,
# `$R->{runsetflags}`, `$R->{client}`). No compat shim is vendored: the
# adapter below IS the whole bridge, per language, per the vendor-tag
# rollout (docs/design/vendor-tag-rollout.md, Decision 4). It is the perl
# peer of tm/ts/test/omni.ts and tm/py/test/omni.py, and it ports the
# value-model conversion from upstream struct's own perl bridge
# (voxgig/struct perl/t/OmniBridge.pm).
#
# Five local decisions, all required:
#
# 1. SPEC PATH. omni's own spec resolution expects the caller to hand it a
#    usable path. A relative path is absolutized against THIS file's
#    directory (t/), so the existing '../../.sdk/test/test.json' constant
#    keeps working verbatim wherever the suite is run from.
#
# 2. TWO VALUE MODELS. omni-perl and this SDK's vendored struct model JSON
#    with different sentinels and they disagree on all of them:
#
#        concept    omni                      SDK / struct-perl
#        -------    ----                      -----------------
#        absent     Voxgig::Omni::Absent      Voxgig::Struct::None
#        null       undef                     Voxgig::Struct::Null (JNULL)
#        boolean    JSON::PP::Boolean         Voxgig::Struct::Bool
#
#    `tostruct` converts arguments IN PLACE (so `match.args` assertions on
#    in-place mutation - minor.setpath, merge.integrity - see the very hash
#    omni holds), `toomni` converts results as a copy. Both are ports of
#    OmniBridge's converters, plus a guard: a live context VIEW (below) is
#    never rewritten. A bare undef result reads as absent, because that is
#    what a perl sub returning nothing means; a JSON null is JNULL here.
#
# 3. ZERO-ARGUMENT ENTRIES. Entries with no `in`, `args` or `ctx` mean
#    "call the subject with no value". omni-perl's native rule passes one
#    Voxgig::Omni::Absent argument; `tostruct` turns it into struct's NONE,
#    which is exactly how this port's struct functions spell "called with
#    nothing" (typify(NONE) is 1073741824 where typify(JNULL) is 4194432).
#    That is the perl form of the correction the lua/php compat shims
#    carry; no entry rewrite is needed here.
#
# 4. MATCH-VISIBLE CONTEXTS. The SDK's context is a BLESSED hash, and
#    omni's ismap()/clone()/getpath() only walk plain ones - against a bare
#    context every `match: {ctx: ...}` assertion would read ABSENT. So
#    `contextify` answers a TIED plain hash (UnivecOmniViewTie) whose
#    reads mirror the live context - snake_case fields answering to the
#    corpus's camelCase keys, struct-model values converted to omni's on
#    the way out - so omni's clone-at-match-time takes a faithful snapshot
#    of the POST-EXECUTION context. Writes route through to the live
#    object, which is how the runner's `ctx.client = provider` assignment
#    lands where prepare_auth and friends read it back. Test subjects
#    unwrap the live context with `livectx` before calling a utility
#    (utilities call methods on it - `$ctx->make_error` - which no
#    unblessed view can answer).
#
# 5. PROVIDER DELEGATION. Corpus-driven contexts get `ctx.client` set to
#    the runner's provider (omni overwrites it on any ctx/args map entry),
#    and generated utilities reach THROUGH it - `$ctx->{client}{features}`,
#    `$ctx->{client}{mode}`, `$ctx->{client}->options_map`. A five-hook
#    provider object would hide the live SDK, so the provider here is a
#    READ-THROUGH view of it: a blessed tied hash whose omni hook keys are
#    its own, whose every other key resolves against the live SDK instance,
#    and whose method calls delegate to it - the perl spelling of ts's
#    prototype delegation. (Upstream omni#56 tracks giving the stock
#    provider the same shape.)
#
# THE VENDORED PERL PORT LACKS THE omni#54 RUNNER FIXES the TypeScript
# port has at this tag (upstream voxgig/omni#64 landed them for js/go/py
# only). Vendored files are resynced, never edited, so each gap is covered
# HERE instead:
#
# a. `match()` clones its base and the vendored clone()/jsonstr() have no
#    cycle guard. Perl's live cycles all pass through BLESSED objects
#    (context -> client -> root context; error -> ctx), which both walks
#    already pass by reference - the exposure is the map-face views this
#    resolver introduces. The view therefore HIDES the cycle edges
#    (`client`/`utility` on every view; `ctx`/`result`/`spec` on error
#    views - runner/SDK bookkeeping the corpus never asserts on) and
#    carries its wrapping ancestry, so a repeated object stays unwrapped
#    and every clone/jsonstr walk terminates.
#
# b. `errify`/`errmessage` collapse non-object throwables via plain
#    stringification. The SDK's own errors are blessed with a '""'
#    overload answering the message, so that gap cannot fire for them;
#    subjects that answer WITH an error value (makePoint) go through
#    `errify` below, which flattens the error to the {code,message} map
#    the corpus asserts on.

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();
use JSON::PP ();

my $__dir;

BEGIN {
  $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__));
  # The vendored omni port keeps its upstream package layout
  # (Voxgig/Omni/*.pm), so it resolves through @INC rather than a
  # file-path require.
  unshift @INC, "$__dir/vendor/omni";
}

use Voxgig::Omni::Runner ();
use Voxgig::Omni::Util ();

require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/../core/context.pm"));


# The corpus spells an entity as `{"name": ...}`; resolve_op wants an
# object with get_name. Nothing else is read from it.
package UnivecOmniEntityRef;

sub new {
  my ($class, $name) = @_;
  return bless { name => $name }, $class;
}

sub get_name { return $_[0]->{name} }


# --------------------------------------------------------------------------
# The map-face view: a TIED plain hash mirroring one live blessed object
# (decision 4 above). Plain, so omni's ismap()/clone()/getpath() walk it;
# tied, so every read is live and every write lands on the object.
# --------------------------------------------------------------------------
package UnivecOmniViewTie;

# Fields the map face does not list. client and utility both reach the
# SDK, whose root context reaches the client again - the cycle omni's
# guardless clone would follow forever; an error's ctx is the same cycle
# one hop in (make_error attaches the live context to every error), and
# its result/spec can hold the error back. Subjects still reach them all
# through the live object; the corpus never asserts on any of them.
my %HIDE = map { $_ => 1 } qw(client utility);
my %HIDE_ERR = map { $_ => 1 } qw(client utility ctx result spec);

sub TIEHASH {
  my ($class, $target, $seen) = @_;
  return bless {
    target => $target,
    seen => $seen || {},
    iter => undef,
    ix => 0,
  }, $class;
}

sub _iserr { return Scalar::Util::blessed($_[0]) && $_[0]->isa('UnivecError') }

sub _names {
  my ($self) = @_;
  my $t = $self->{target};
  my $hide = _iserr($t) ? \%HIDE_ERR : \%HIDE;
  return [ sort grep {
    !$hide->{$_} && !/^_/ && defined $t->{$_}
  } keys %$t ];
}

# `status_text` -> `statusText`: the corpus speaks camelCase, the SDK is
# snake_case, and the map face is the corpus-facing side. An error's `msg`
# field answers to the corpus's `message`.
sub _camel {
  my ($self, $name) = @_;
  return 'message' if 'msg' eq $name && _iserr($self->{target});
  my @parts = split /_/, $name, -1;
  my $first = shift @parts;
  $first = '' unless defined $first;
  return $first . join('', map { length($_) ? ucfirst($_) : $_ } @parts);
}

sub _snake {
  my ($name) = @_;
  (my $s = $name) =~ s/([A-Z])/'_' . lc($1)/ge;
  return $s;
}

sub _attrname {
  my ($self, $key) = @_;
  my $t = $self->{target};
  $key = defined $key ? "$key" : '';
  return 'msg' if 'message' eq $key && _iserr($t) && !exists $t->{message};
  return $key if exists $t->{$key};
  my $snake = _snake($key);
  return $snake if exists $t->{$snake};
  return undef;
}

sub _wrap {
  my ($self, $name, $val) = @_;
  my $t = $self->{target};
  my $seen = $self->{seen};

  # The live cycle edges stay raw: readable through the view, invisible
  # to its key list (workaround a above).
  return $val if 'client' eq $name || 'utility' eq $name;

  # The corpus asserts `result.ok` as a JSON boolean; the SDK stores 1/0.
  if ('ok' eq $name && Scalar::Util::blessed($t) && $t->isa('UnivecResult')
    && defined $val && !ref $val) {
    return $val ? JSON::PP::true : JSON::PP::false;
  }

  # A view held INSIDE the object graph continues THIS traversal's
  # ancestry, not its own - a restarted chain never terminates on the
  # cycle it re-enters.
  if (ref($val) eq 'HASH' && tied(%$val)
    && tied(%$val)->isa('UnivecOmniViewTie')) {
    my $inner = tied(%$val)->{target};
    return $inner if $seen->{ Scalar::Util::refaddr($inner) };
    return UnivecOmni::objview($inner,
      { %$seen, Scalar::Util::refaddr($t) => 1 });
  }

  if (Scalar::Util::blessed($val)) {
    return undef if Voxgig::Struct::is_jnull($val);
    return ($$val ? JSON::PP::true : JSON::PP::false)
      if Voxgig::Struct::is_jbool($val);
    return Voxgig::Omni::Util::ABSENT() if Voxgig::Struct::is_none($val);
    return $val if $val->isa('Voxgig::Omni::Absent');

    # A blessed hash (Spec, Result, Response, Error, Operation, Control,
    # ...) becomes a nested view; a repeated object stays unwrapped, which
    # match reads as ABSENT - no corpus case matches into a cycle.
    if (('HASH' eq (Scalar::Util::reftype($val) || ''))) {
      return $val if $seen->{ Scalar::Util::refaddr($val) };
      return UnivecOmni::objview($val,
        { %$seen, Scalar::Util::refaddr($t) => 1 });
    }

    return $val;
  }

  # Plain containers hold struct-model DATA (the contextified corpus
  # input, SDK-built maps): convert a copy to omni's model so match's
  # deepequal sees the values the corpus wrote.
  if (ref($val) eq 'HASH' || ref($val) eq 'ARRAY') {
    return UnivecOmni::toomni($val);
  }

  return $val;
}

sub FETCH {
  my ($self, $key) = @_;
  my $name = $self->_attrname($key);
  return undef if !defined $name;
  return $self->_wrap($name, $self->{target}{$name});
}

sub STORE {
  my ($self, $key, $val) = @_;
  my $name = $self->_attrname($key);
  $name = _snake(defined $key ? "$key" : '') if !defined $name;
  $self->{target}{$name} = $val;
  return $val;
}

sub EXISTS {
  my ($self, $key) = @_;
  my $name = $self->_attrname($key);
  return 0 if !defined $name;
  # An undef-valued field is "not set" (perl's spelling of ts undefined):
  # mirroring it as present would let `__EXISTS__` accept an unset field.
  return defined $self->{target}{$name} ? 1 : 0;
}

sub DELETE {
  my ($self, $key) = @_;
  my $name = $self->_attrname($key);
  return defined $name ? delete $self->{target}{$name} : undef;
}

sub CLEAR { return }

sub FIRSTKEY {
  my ($self) = @_;
  $self->{iter} = [ map { $self->_camel($_) } @{ $self->_names } ];
  $self->{ix} = 0;
  return $self->NEXTKEY;
}

sub NEXTKEY {
  my ($self) = @_;
  my $it = $self->{iter} || [];
  my $i = $self->{ix}++;
  return $i <= $#$it ? $it->[$i] : undef;
}

sub SCALAR {
  my ($self) = @_;
  return scalar @{ $self->_names };
}


# --------------------------------------------------------------------------
# The provider (decision 5): a blessed tied hash. Hash reads answer the
# omni hooks first and fall through to the live SDK's own fields
# (features, mode); method calls delegate to the SDK.
# --------------------------------------------------------------------------
package UnivecOmniProviderTie;

sub TIEHASH {
  my ($class, $sdk, $hooks) = @_;
  return bless { sdk => $sdk, hooks => $hooks, iter => undef, ix => 0 }, $class;
}

sub FETCH {
  my ($self, $key) = @_;
  return exists $self->{hooks}{$key} ? $self->{hooks}{$key} : $self->{sdk}{$key};
}

sub STORE {
  my ($self, $key, $val) = @_;
  if (exists $self->{hooks}{$key}) { $self->{hooks}{$key} = $val }
  else { $self->{sdk}{$key} = $val }
  return $val;
}

sub EXISTS {
  my ($self, $key) = @_;
  return exists $self->{hooks}{$key} || exists $self->{sdk}{$key};
}

sub DELETE { my ($self, $key) = @_; return delete $self->{hooks}{$key} }
sub CLEAR { return }

sub FIRSTKEY {
  my ($self) = @_;
  $self->{iter} = [ sort keys %{ $self->{hooks} } ];
  $self->{ix} = 0;
  return $self->NEXTKEY;
}

sub NEXTKEY {
  my ($self) = @_;
  my $it = $self->{iter} || [];
  my $i = $self->{ix}++;
  return $i <= $#$it ? $it->[$i] : undef;
}

sub SCALAR { return 1 }


package UnivecOmniProvider;

our $AUTOLOAD;

sub AUTOLOAD {
  my $self = shift;
  (my $name = $AUTOLOAD) =~ s/.*:://;
  return if 'DESTROY' eq $name;
  my $sdk = tied(%$self)->{sdk};
  return $sdk->$name(@_);
}


# --------------------------------------------------------------------------
# The resolver proper.
# --------------------------------------------------------------------------
package UnivecOmni;

my $DIR = $__dir;

# Re-exported so the suites need no direct reach into the vendored tree.
use constant NULLMARK => Voxgig::Omni::Util::NULLMARK;
use constant UNDEFMARK => Voxgig::Omni::Util::UNDEFMARK;
use constant EXISTSMARK => Voxgig::Omni::Util::EXISTSMARK;

sub is_omni_error { return Voxgig::Omni::Runner::is_omni_error($_[0]) }

sub objview {
  my ($target, $seen) = @_;
  tie my %view, 'UnivecOmniViewTie', $target, $seen;
  return \%view;
}

sub isview {
  my ($val) = @_;
  return ref($val) eq 'HASH' && tied(%$val)
    && tied(%$val)->isa('UnivecOmniViewTie') ? 1 : 0;
}

# The live object behind a view (subjects call methods on it).
sub livectx {
  my ($val) = @_;
  return isview($val) ? tied(%$val)->{target} : $val;
}

# omni's model -> this port's, rewriting containers in place (decision 2).
# Safe: resolveargs clones `entry->{in}` and the runner's testspec is a
# fresh fixjson copy, so the containers rewritten are never the loaded
# spec's own.
sub tostruct {
  my ($val) = @_;

  return Voxgig::Struct::NONE() if Voxgig::Omni::Util::isabsent($val);
  return Voxgig::Struct::JNULL() if !defined $val;
  return ($val ? Voxgig::Struct::JTRUE() : Voxgig::Struct::JFALSE())
    if JSON::PP::is_bool($val);

  if (ref($val) eq 'HASH') {
    return $val if isview($val);
    for my $key (keys %$val) {
      $val->{$key} = tostruct($val->{$key});
    }
    return $val;
  }

  if (ref($val) eq 'ARRAY') {
    for my $index (0 .. $#$val) {
      $val->[$index] = tostruct($val->[$index]);
    }
    return $val;
  }

  return $val;
}

# This port's model -> omni's, as a copy. A bare undef reads as absent: a
# perl sub that returns nothing returns undef, and this port spells a JSON
# null JNULL, so undef here is never "null".
sub toomni {
  my ($val) = @_;

  return $val if Voxgig::Omni::Util::isabsent($val);
  return Voxgig::Omni::Util::ABSENT()
    if !defined $val || Voxgig::Struct::is_none($val);
  return undef if Voxgig::Struct::is_jnull($val);
  return ($$val ? JSON::PP::true : JSON::PP::false)
    if Voxgig::Struct::is_jbool($val);

  if (ref($val) eq 'HASH') {
    return $val if isview($val);
    my %out;
    for my $key (Voxgig::Struct::_map_keys($val)) {
      $out{$key} = toomni($val->{$key});
    }
    return \%out;
  }

  if (ref($val) eq 'ARRAY') {
    return [ map { toomni($_) } @$val ];
  }

  return $val;
}

# A subject whose arguments arrive in struct's model and whose result
# leaves in omni's.
sub wrapsubject {
  my ($subject) = @_;
  return $subject if ref($subject) ne 'CODE';
  return sub {
    my @conv = map { tostruct($_) } @_;
    return toomni($subject->(@conv));
  };
}

# The JSON form of an error VALUE, with the error's own fields carried
# along - what a subject answers when the corpus asserts a refusal by code
# (makePoint's `match: {out: {code: ...}}`).
our %HIDE_ERRFIELD = map { $_ => 1 } qw(ctx result spec msg);

sub errify {
  my ($err) = @_;
  return $err if !Scalar::Util::blessed($err);
  my %out = ( name => ref($err), message => "$err" );
  if ('HASH' eq (Scalar::Util::reftype($err) || '')) {
    for my $key (keys %$err) {
      next if $key =~ /^_/ || $HIDE_ERRFIELD{$key};
      my $val = $err->{$key};
      $out{$key} = $val if defined $val && !ref $val;
    }
  }
  return \%out;
}

# The sdkgen corpus writes contexts as pure JSON, and the perl context
# constructor only adopts spec/result/response given as INSTANCES - so the
# JSON forms are materialised here, exactly as the retired inline runner's
# make_ctx_from_map did.
sub enrich {
  my ($ctxmap, $ctx) = @_;

  if (Voxgig::Struct::ismap($ctxmap->{spec}) && !Scalar::Util::blessed($ctxmap->{spec})) {
    $ctx->{spec} = UnivecSpec->new($ctxmap->{spec});
  }

  my $res_map = $ctxmap->{result};
  if (Voxgig::Struct::ismap($res_map) && !Scalar::Util::blessed($res_map)) {
    $ctx->{result} = UnivecResult->new($res_map);
    if (Voxgig::Struct::ismap($res_map->{err})
      && defined $res_map->{err}{message} && !ref $res_map->{err}{message}) {
      $ctx->{result}{err} = UnivecError->new('', $res_map->{err}{message});
    }
  }

  my $resp_map = $ctxmap->{response};
  if (Voxgig::Struct::ismap($resp_map) && !Scalar::Util::blessed($resp_map)) {
    $ctx->{response} = UnivecResponse->new($resp_map);
    if (UnivecHelpers::rb_truthy($resp_map->{body})) {
      my $body_copy = $resp_map->{body};
      $ctx->{response}{json_func} = sub { $body_copy };
    }
    if (Voxgig::Struct::ismap($resp_map->{headers})) {
      my $lower = {};
      $lower->{lc $_} = $resp_map->{headers}{$_} for keys %{ $resp_map->{headers} };
      $ctx->{response}{headers} = $lower;
    }
  }

  return $ctx;
}

# The omni hooks for an SDK subject - what upstream's compat shims call
# structprovider, inlined here because this resolver is the one consumer.
sub sdkhooks {
  my ($sdk) = @_;
  my $utility = $sdk->get_utility;
  my $struct = $utility->{struct} || UnivecHelpers::struct_facade();

  my $subject = sub {
    # A subject resolves from the utility (the corpus's camelCase name in
    # perl's snake_case spelling), or from the struct facade.
    my ($name) = @_;
    return undef if !defined $name;
    my $found = $utility->{$name};
    $found = $utility->{ UnivecOmniViewTie::_snake($name) } if !defined $found;
    $found = $struct->{$name} if !defined $found;
    return ref($found) eq 'CODE' ? wrapsubject($found) : undef;
  };

  my $client = sub {
    # A DEF.client entry becomes another SDK instance - rewrapped with the
    # same delegating shape, not a plain hook object.
    my ($options) = @_;
    return sdkprovider(ref($sdk)->test(undef, tostruct($options)));
  };

  my $contextify = sub {
    my ($val) = @_;
    my $ctxmap = Voxgig::Omni::Util::ismap($val) ? $val : {};
    tostruct($ctxmap);
    my $ent = $ctxmap->{entity};
    if (Voxgig::Struct::ismap($ent) && !Scalar::Util::blessed($ent)
      && defined $ent->{name} && !ref $ent->{name}) {
      $ctxmap->{entity} = UnivecOmniEntityRef->new($ent->{name});
    }
    my $ctx = UnivecContext->new($ctxmap, undef);
    enrich($ctxmap, $ctx);
    $ctx->{utility} = $utility;
    $ctx->{options} = $sdk->options_map if !defined $ctx->{options};
    return objview($ctx);
  };

  my $inject = sub {
    # Client options may reference the runner store.
    my ($options, $store) = @_;
    my $injector = $struct->{inject};
    return ref($injector) eq 'CODE' ? $injector->($options, $store) : $options;
  };

  return {
    subject => $subject,
    client => $client,
    contextify => $contextify,
    inject => $inject,
    sdk => $sdk,
  };
}

sub sdkprovider {
  my ($sdk) = @_;
  tie my %provider, 'UnivecOmniProviderTie', $sdk, sdkhooks($sdk);
  return bless \%provider, 'UnivecOmniProvider';
}

# struct's make_runner(testfile, client) signature, backed by vendored
# omni. Also accepts an already-parsed spec structure (omni's own
# capability), which keeps smoke tests free of fixture files.
sub make_runner {
  my ($testfile, $client) = @_;

  my $specref = $testfile;
  if (defined $testfile && !ref $testfile && $testfile !~ m{^/}) {
    $specref = Cwd::abs_path("$DIR/$testfile") || "$DIR/$testfile";
  }

  my $provider = sdkprovider($client);
  my $runner = Voxgig::Omni::Runner::makeRunner($specref, $provider);

  return sub {
    my ($name, $store) = @_;
    my $runpack = $runner->($name, defined $store ? $store : {});

    my $omniflags = $runpack->{runsetflags};

    # Explicitly passed subjects get the model conversion too - the
    # corpus tests hand most subjects in per-set rather than by name.
    my $runsetflags = sub {
      my ($testspec, $flags, $testsubject) = @_;
      return $omniflags->($testspec, $flags || {},
        defined $testsubject ? wrapsubject($testsubject) : undef);
    };

    my $runset = sub {
      my ($testspec, $testsubject) = @_;
      return $runsetflags->($testspec, {}, $testsubject);
    };

    return {
      spec => $runpack->{spec},
      runset => $runset,
      runsetflags => $runsetflags,
      subject => $runpack->{subject},
      client => $provider,
    };
  };
}

# struct's flag-modifier, in THIS port's value model: omni's own
# nullmodifier writes omni's null (undef), but the values it modifies flow
# into struct subjects, whose null is JNULL (ported from upstream struct's
# t/struct.t).
sub null_modifier {
  my ($val, $key, $parent) = @_;
  return if !defined $parent || !ref $parent;
  return if ref $val || !defined $val;

  my $nullmark = NULLMARK;
  if ($val eq $nullmark) {
    Voxgig::Struct::setprop($parent, $key, Voxgig::Struct::JNULL());
  }
  elsif (0 <= index($val, $nullmark)) {
    my $text = $val;
    $text =~ s/\Q$nullmark\E/null/g;
    Voxgig::Struct::setprop($parent, $key, $text);
  }
  return;
}

1;
