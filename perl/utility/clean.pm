# Univec SDK utility: clean

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();
use MIME::Base64 ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/../schema.pm"));

# Everything that leaves the pipeline passes through clean: the error, the
# explain record, the serialised context, and whatever a feature emits.
# Two layers: every registered secret VALUE (and its encoded forms) is
# replaced wherever it appears in a string, and every value under a
# sensitive KEY name is masked whatever it holds. Inside the pipeline data
# stays raw, so a hook can still read the header it must add to.
package UnivecCleanSupport;

my $MAXDEPTH = 32;
my $CIRCULAR = '[circular]';

# Marks a value the copy omits (a coderef), as ts omits `undefined`.
my $DROP = \'drop';

sub _dropped {
  my ($v) = @_;
  return ref $v && Scalar::Util::refaddr($v) == Scalar::Util::refaddr($DROP) ? 1 : 0;
}

sub normkey {
  my ($key) = @_;
  my $k = lc("$key");
  $k =~ s/[-_]//g;
  return $k;
}

sub splitkeys {
  my ($keys) = @_;
  return [] unless defined $keys && !ref $keys;
  return [ grep { '' ne $_ } map { normkey($_) } split /\s*,\s*/, "$keys" ];
}

# The comma-separated literal values a caller registers; a list is taken
# as-is for a caller that has one.
sub splitvalues {
  my ($values) = @_;
  if (Voxgig::Struct::islist($values)) {
    return [ grep { defined $_ && !ref $_ } @$values ];
  }
  return [] unless defined $values && !ref $values;
  return [ grep { '' ne $_ } split /\s*,\s*/, "$values" ];
}

# The spec carries numbers as strings, so every target reads it alike.
sub count {
  my ($val, $dflt) = @_;
  return $dflt unless defined $val && !ref $val && Scalar::Util::looks_like_number($val);
  my $n = int($val);
  return $n < 0 ? $dflt : $n;
}

# The derived block make_options builds; a context without options
# (make_error is reached with a bare one) falls back to the schema
# defaults, so nothing leaves raw for want of a constructor. A plain hash
# stands in for a context before one exists (make_options).
sub config {
  my ($ctx) = @_;
  my $opts = (defined $ctx && ref $ctx && (Scalar::Util::reftype($ctx) // '') eq 'HASH')
    ? $ctx->{options} : undef;
  my $derived = Voxgig::Struct::ismap($opts) ? $opts->{__derived__} : undef;
  my $cfg = Voxgig::Struct::ismap($derived) ? $derived->{clean} : undef;
  return $cfg if Voxgig::Struct::ismap($cfg) && Voxgig::Struct::islist($cfg->{values});
  return make_config(UnivecSchema::optspec()->{clean});
}

sub make_config {
  my ($cleanopts) = @_;
  my $o = Voxgig::Struct::ismap($cleanopts) ? $cleanopts : {};
  my $min = count($o->{min}, 4);
  return {
    'active' => UnivecHelpers::is_false($o->{active}) ? 0 : 1,
    'keys' => splitkeys($o->{keys}),
    'values' => [],
    'mask' => (defined $o->{mask} && !ref $o->{mask}) ? "$o->{mask}" : '[redacted]',
    'hint' => count($o->{hint}, 0),
    'min' => ($min < 1 ? 1 : $min),
  };
}

# encodeURIComponent, byte for byte: the form a query credential travels in.
sub pct {
  my ($value) = @_;
  my $b = "$value";
  utf8::encode($b) if utf8::is_utf8($b);
  $b =~ s/([^A-Za-z0-9\-_.!~*'()])/sprintf('%%%02X', ord($1))/ge;
  return $b;
}

# The JSON string escape, as a JSON dump would write the value.
sub jsonesc {
  my ($value) = @_;
  my $s = "$value";
  $s =~ s/\\/\\\\/g;
  $s =~ s/"/\\"/g;
  $s =~ s/\n/\\n/g;
  $s =~ s/\r/\\r/g;
  $s =~ s/\t/\\t/g;
  $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
  return $s;
}

# The encoded forms a value travels in: Basic and Bearer both carry base64,
# a query credential is percent-encoded, and a JSON dump escapes it.
sub forms {
  my ($value) = @_;
  my @out = ("$value");
  my $add = sub {
    my ($s) = @_;
    push @out, $s if defined $s && '' ne $s && !grep { $_ eq $s } @out;
  };
  my $b = "$value";
  utf8::encode($b) if utf8::is_utf8($b);
  $add->(MIME::Base64::encode_base64($b, ''));
  $add->(pct($value));
  $add->(jsonesc($value));
  return @out;
}

# Register a secret value. Idempotent; shorter than `min` is not a secret
# the SDK can mask without blanking ordinary text.
sub add {
  my ($ctx, $value) = @_;
  my $cfg = config($ctx);
  return unless defined $value && !ref $value && length("$value") >= $cfg->{min};
  my $values = $cfg->{values};
  my $changed = 0;
  for my $form (forms($value)) {
    next if length($form) < $cfg->{min} || grep { $_ eq $form } @$values;
    push @$values, $form;
    $changed = 1;
  }
  @$values = sort { length($b) <=> length($a) } @$values if $changed;
  return;
}

sub mask_value {
  my ($cfg, $value) = @_;
  my $hint = $cfg->{hint};
  return $cfg->{mask} . substr($value, -$hint) if $hint > 0 && length($value) > 2 * $hint;
  return $cfg->{mask};
}

# The scalar comes back untouched when no value matches, so a number stays
# a number.
sub clean_string {
  my ($cfg, $text) = @_;
  my $out = $text;
  my $hit = 0;
  for my $value (@{ $cfg->{values} }) {
    next if index("$out", $value) < 0;
    my $masked = mask_value($cfg, $value);
    my $q = quotemeta $value;
    $out = "$out";
    $out =~ s/$q/$masked/g;
    $hit = 1;
  }
  return $hit ? $out : $text;
}

sub sensitive_key {
  my ($cfg, $key) = @_;
  return 0 unless defined $key && !ref $key;
  my $nk = normkey($key);
  for my $k (@{ $cfg->{keys} }) {
    return 1 if index($nk, $k) >= 0;
  }
  return 0;
}

# A plain-data copy of what is about to leave: TO_JSON is honoured (an
# entity gives its data, a context its record), coderefs are dropped,
# cycles are cut, and no live object is shared with the copy - masking the
# copy must never mask the pipeline's own spec. Any other blessed hash
# copies as its fields; the error keeps its context out of them.
sub snapshot {
  my ($cfg, $val, $key, $depth, $seen) = @_;
  return $val unless defined $val;

  if (!ref $val) {
    return sensitive_key($cfg, $key) ? mask_value($cfg, "$val") : clean_string($cfg, $val);
  }

  if (Voxgig::Struct::is_jbool($val) || Voxgig::Struct::is_jnull($val) || Voxgig::Struct::is_none($val)) {
    return sensitive_key($cfg, $key) ? $cfg->{mask} : $val;
  }

  my $type = Scalar::Util::reftype($val) // '';
  return $DROP unless 'HASH' eq $type || 'ARRAY' eq $type;

  my $addr = Scalar::Util::refaddr($val);
  return $CIRCULAR if $depth >= $MAXDEPTH || $seen->{$addr};
  return $cfg->{mask} if sensitive_key($cfg, $key);

  $seen->{$addr} = 1;
  my $out;
  if ('ARRAY' eq $type) {
    $out = [];
    for (my $i = 0; $i < @$val; $i++) {
      my $v = snapshot($cfg, $val->[$i], "$i", $depth + 1, $seen);
      push @$out, $v unless _dropped($v);
    }
  }
  elsif (Scalar::Util::blessed($val) && $val->isa('UnivecError')) {
    $out = plain($cfg, $val, $depth, $seen);
    $out->{message} = clean_string($cfg, defined $val->{msg} ? "$val->{msg}" : '');
  }
  elsif (Scalar::Util::blessed($val) && $val->can('TO_JSON')) {
    my $json = eval { $val->TO_JSON };
    $out = $@ ? plain($cfg, $val, $depth, $seen) : snapshot($cfg, $json, $key, $depth + 1, $seen);
  }
  else {
    $out = plain($cfg, $val, $depth, $seen);
  }
  delete $seen->{$addr};
  return $out;
}

sub plain {
  my ($cfg, $val, $depth, $seen) = @_;
  my $out = {};
  for my $k (sort keys %$val) {
    my $v = snapshot($cfg, $val->{$k}, $k, $depth + 1, $seen);
    $out->{ clean_name($cfg, $out, $k) } = $v unless _dropped($v);
  }
  return $out;
}

# A registered value used as a property name is masked like any other
# string; names that mask alike take a counter, so none is lost. Callers
# visit keys sorted, so the counters are stable.
sub clean_name {
  my ($cfg, $out, $key) = @_;
  my $name = clean_string($cfg, $key);
  return $name if $name eq $key || !exists $out->{$name};
  my $i = 1;
  $i++ while exists $out->{"$name#$i"};
  return "$name#$i";
}

# Clean a value on its way out. A string is redacted; an SDK error is
# redacted IN PLACE (it is about to be thrown, and its identity matters to
# the caller); another blessed object is not this SDK's to rewrite and comes
# back as it is; anything else comes back as a masked plain-data copy.
sub clean {
  my ($ctx, $val) = @_;
  my $cfg = config($ctx);

  return $val unless $cfg->{active};
  return $val unless defined $val;
  return clean_string($cfg, $val) unless ref $val;

  if (Scalar::Util::blessed($val)) {
    return $val unless $val->isa('UnivecError');
    $val->{msg} = clean_string($cfg, "$val->{msg}") if defined $val->{msg};
    for my $k (sort keys %$val) {
      next if 'msg' eq $k;
      my $v = $val->{$k};
      if (defined $v && !ref $v) {
        $v = sensitive_key($cfg, $k) ? mask_value($cfg, "$v") : clean_string($cfg, $v);
      }
      elsif (ref $v && (Scalar::Util::reftype($v) // '') =~ /\A(?:HASH|ARRAY)\z/) {
        $v = snapshot($cfg, $v, $k, 1, {});
      }
      my $name = clean_string($cfg, $k);
      delete $val->{$k} if $name ne $k;
      $val->{ $name eq $k ? $k : clean_name($cfg, $val, $k) } = $v;
    }
    return $val;
  }

  my $out = snapshot($cfg, $val, undef, 0, {});
  return _dropped($out) ? undef : $out;
}

# Every scalar under a sensitive name, at any depth and of any shape: a
# credential mistyped as a map or a number is still a credential, and the
# validation error that rejects it quotes it.
sub add_sensitive {
  my ($ctx, $val, $under, $depth, $seen) = @_;
  $depth //= 0;
  $seen //= {};
  return if !defined $val || $depth >= $MAXDEPTH;
  if (!ref $val) {
    add($ctx, "$val") if $under;
    return;
  }
  my $type = Scalar::Util::reftype($val) // '';
  return unless 'HASH' eq $type || 'ARRAY' eq $type;
  return if $seen->{ Scalar::Util::refaddr($val) }++;
  if ('HASH' eq $type) {
    add_sensitive($ctx, $val->{$_}, $under || key($ctx, $_), $depth + 1, $seen) for keys %$val;
  }
  else {
    add_sensitive($ctx, $_, $under, $depth + 1, $seen) for @$val;
  }
  return;
}

# A feature's name is not a field name: only the sensitive names inside its
# settings count, so `secrets` does not make every setting a secret. Entity
# blocks (per-entity settings, seeded records) hold no credential, and nor do
# rbac's rules, keyed by entity and operation names.
sub add_options {
  my ($ctx, $opts) = @_;
  my %scan = %$opts;
  my $feature = delete $scan{feature};
  delete $scan{entity};
  $scan{test} = plain_settings($scan{test}) if exists $scan{test};
  add_sensitive($ctx, \%scan);
  my @blocks = Voxgig::Struct::ismap($feature)
    ? map { [$_, $feature->{$_}] } sort keys %$feature
    : Voxgig::Struct::islist($feature)
    ? map { [Voxgig::Struct::ismap($_) ? $_->{name} : undef, $_] } @$feature
    : ([undef, $feature]);
  add_sensitive($ctx, plain_settings($_->[1], $_->[0])) for @blocks;
  return;
}

sub plain_settings {
  my ($block, $name) = @_;
  return $block unless Voxgig::Struct::ismap($block);
  my %copy = %$block;
  delete $copy{entity};
  delete $copy{rules} if defined $name && 'rbac' eq $name;
  return \%copy;
}

# Is this key name sensitive under the context's clean configuration?
sub key {
  my ($ctx, $key) = @_;
  return sensitive_key(config($ctx), $key);
}

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{clean} = sub {
  my ($ctx, $val) = @_;
  return UnivecCleanSupport::clean($ctx, $val);
};

$REGISTRY{clean_add} = sub {
  my ($ctx, $value) = @_;
  return UnivecCleanSupport::add($ctx, $value);
};

1;
