# Vendored from voxgig/struct/perl (adapted).
# Test runner that uses the test model in .sdk/test - mirrors the rb
# struct_runner make_runner protocol on top of the perl struct port.

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package StructRunner;

our $NULLMARK = '__NULL__';   # Represents a JSON null in tests
our $UNDEFMARK = '__UNDEF__'; # Represents an undefined value

# Canonical comparison string: sorted-key JSON so key order is ignored
# (matches node's deepStrictEqual over the corpus).
sub canon {
  my ($v) = @_;
  return Voxgig::Struct::_stringify_inner($v, 1);
}

# make_runner($testfile, $client)
# Returns a sub that accepts a name (e.g. "struct") and an optional store,
# and returns a hash (runpack) with:
#   spec        -> the extracted spec for that name,
#   runset      -> a sub to run a test set without extra flags,
#   runsetflags -> a sub to run a test set with flags,
#   subject     -> the function (from the client utility) under test,
#   client      -> the client instance.
sub make_runner {
  my ($testfile, $client) = @_;
  return sub {
    my ($name, $store) = @_;
    $store = {} unless defined $store;

    my $utility = $client->utility;
    my $struct_utils = $utility->{struct};

    my $spec = resolve_spec($name, $testfile);
    my $clients = resolve_clients($client, $spec, $store, $struct_utils);
    my $subject = resolve_subject($name, $utility);

    my $runsetflags = sub {
      my ($testspec, $flags, $testsubject) = @_;
      my $use_subject = defined $testsubject ? $testsubject : $subject;
      $flags = resolve_flags($flags);
      my $testset = (Voxgig::Struct::ismap($testspec) && $testspec->{set}) || [];
      my $idx = 0;
      for my $entry (@{ Voxgig::Struct::islist($testset) ? $testset : [] }) {
        next unless Voxgig::Struct::ismap($entry);
        my $this_subject = $use_subject;
        if (exists $entry->{client} && defined $clients->{ $entry->{client} }) {
          my $cutil = $clients->{ $entry->{client} }->utility;
          $this_subject = resolve_subject($name, $cutil);
        }
        my @args = resolve_args($entry);
        my $got = eval { $this_subject->(@args) };
        my $err = $@;
        check_entry($name, $idx, $entry, $got, $err);
        $idx++;
      }
    };

    my $runset = sub {
      my ($testspec, $testsubject) = @_;
      $runsetflags->($testspec, {}, $testsubject);
    };

    return {
      spec => $spec,
      runset => $runset,
      runsetflags => $runsetflags,
      subject => $subject,
      client => $client,
    };
  };
}

# Loads the test JSON file and extracts the spec for the given name.
# Follows the pattern: alltests.primary?[name] || alltests[name] || alltests.
sub resolve_spec {
  my ($name, $testfile) = @_;
  my $text = do {
    open my $fh, '<:raw', $testfile or die "Cannot open $testfile: $!";
    local $/;
    <$fh>;
  };
  my $all_tests = Voxgig::Struct::parse_json($text);
  if (Voxgig::Struct::ismap($all_tests->{primary})
    && Voxgig::Struct::ismap($all_tests->{primary}{$name})) {
    return $all_tests->{primary}{$name};
  }
  return $all_tests->{$name} if Voxgig::Struct::ismap($all_tests->{$name});
  return $all_tests;
}

# If the spec contains a DEF section with client definitions, resolve them.
sub resolve_clients {
  my ($client, $spec, $store, $struct_utils) = @_;
  my $clients = {};
  my $defs = Voxgig::Struct::ismap($spec) ? $spec->{DEF} : undef;
  if (Voxgig::Struct::ismap($defs) && Voxgig::Struct::ismap($defs->{client})) {
    for my $cn (keys %{ $defs->{client} }) {
      my $cdef = $defs->{client}{$cn};
      my $copts = (Voxgig::Struct::ismap($cdef->{test})
        && Voxgig::Struct::ismap($cdef->{test}{options}))
        ? $cdef->{test}{options} : {};
      $clients->{$cn} = $client->test($copts);
    }
  }
  return $clients;
}

# Returns the subject under test: the named entry of the utility map.
sub resolve_subject {
  my ($name, $container, $subject) = @_;
  return $subject if defined $subject;
  return undef unless defined $container;
  return $container->{$name} if ref($container) eq 'HASH'
    || (Scalar::Util::reftype($container) // '') eq 'HASH';
  return undef;
}

# Ensure flags is a hash and set "null" flag to 1 if not provided.
sub resolve_flags {
  my ($flags) = @_;
  $flags = {} unless defined $flags && ref $flags;
  $flags->{null} = 1 unless exists $flags->{null};
  return $flags;
}

# By default pass a clone of entry.in; entry.ctx / entry.args override.
sub resolve_args {
  my ($entry) = @_;
  my @args;
  if (exists $entry->{ctx}) {
    @args = ($entry->{ctx});
  }
  elsif (exists $entry->{args}) {
    my $a = $entry->{args};
    @args = Voxgig::Struct::islist($a) ? @$a : ($a);
  }
  elsif (exists $entry->{in}) {
    @args = (Voxgig::Struct::clone($entry->{in}), $entry);
  }
  else {
    @args = (undef, $entry);
  }
  return @args;
}

# Compare the run outcome against the entry (out / err / match).
sub check_entry {
  my ($label_base, $idx, $entry, $got, $err) = @_;
  my $label = "$label_base#$idx";
  my $err_field = $entry->{err};

  if (defined $err_field) {
    # An error is expected: the subject must throw, and (unless err is
    # literally true) the thrown message must contain the expected
    # substring or match the /regex/.
    if (!$err) {
      die "[$label] expected error but none thrown (err=" . canon($err_field) . ")\n";
    }
    my $msg = "$err";
    my $ok;
    if (Voxgig::Struct::is_jbool($err_field)) {
      $ok = $$err_field ? 1 : 0;   # err: true -> any error
    }
    elsif (!ref $err_field) {
      if ($err_field =~ m{^/(.+)/$}s) {
        my $re = $1;
        $ok = ($msg =~ /$re/) ? 1 : 0;
      }
      else {
        $ok = (index(lc $msg, lc $err_field) >= 0) ? 1 : 0;
      }
    }
    else {
      $ok = 1;
    }
    die "[$label] ERROR MATCH: [" . canon($err_field) . "] <=> [$msg]\n" unless $ok;
    return;
  }

  die "[$label] unexpected error: $err\n" if $err;

  # Optional deep match against { in, out }.
  if (Voxgig::Struct::ismap($entry->{match})) {
    my $base = { 'in' => $entry->{in}, 'out' => $got };
    match($label, $entry->{match}, $base);
  }

  my $expected = exists $entry->{out} ? $entry->{out} : undef;
  my $got_j = canon($got);
  my $exp_j = canon($expected);
  if ($got_j ne $exp_j) {
    die "[$label] Mismatch: Expected $exp_j but got $got_j\n";
  }
  return;
}

# Compares scalar values along each path of the check structure against
# the base.
sub match {
  my ($label, $check, $base) = @_;
  _match_walk($label, $check, $base, []);
  return;
}

sub _match_walk {
  my ($label, $val, $base, $path) = @_;
  if (Voxgig::Struct::ismap($val)) {
    for my $k (keys %$val) {
      _match_walk($label, $val->{$k}, $base, [@$path, $k]);
    }
  }
  elsif (Voxgig::Struct::islist($val)) {
    for my $i (0 .. $#$val) {
      _match_walk($label, $val->[$i], $base, [@$path, $i]);
    }
  }
  else {
    my $baseval = UnivecHelpers::gpath($base, [@$path]);
    return if canon($val) eq canon($baseval);
    return if defined $val && !ref($val) && $val eq $UNDEFMARK && !defined $baseval;
    if (matchval($val, $baseval)) {
      return;
    }
    die "[$label] MATCH: " . join('.', @$path) . ' : ['
      . canon($val) . '] <=> [' . canon($baseval) . "]\n";
  }
  return;
}

sub matchval {
  my ($check, $base) = @_;
  return 1 if canon($check) eq canon($base);
  if (defined $check && !ref $check) {
    my $basestr = Voxgig::Struct::stringify($base);
    if ($check =~ m{^/(.+)/$}s) {
      my $re = $1;
      return ($basestr =~ /$re/) ? 1 : 0;
    }
    return (index(lc $basestr, lc Voxgig::Struct::stringify($check)) >= 0) ? 1 : 0;
  }
  return ref $check eq 'CODE' ? 1 : 0;
}

# StructTestClient is a minimal shim that provides the client interface
# needed by the struct test runner within the SDK context.
package StructTestClient;

sub new {
  my ($class) = @_;
  return bless {}, $class;
}

sub utility {
  return { struct => UnivecHelpers::struct_facade() };
}

sub test {
  my ($self, $options) = @_;
  return $self;
}

1;
