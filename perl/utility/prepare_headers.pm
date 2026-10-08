# Univec SDK utility: prepare_headers

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/param.pm"));
require(Cwd::abs_path("$__dir/media.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{prepare_headers} = sub {
  my ($ctx) = @_;
  my $options = $ctx->{client}->options_map;
  my $headers = UnivecHelpers::gp($options, 'headers');
  my $out = UnivecHelpers::rb_truthy($headers) ? Voxgig::Struct::clone($headers) : {};
  $out = {} unless Voxgig::Struct::ismap($out);
  $out = UnivecUtilities::media_headers($ctx->{point}, $out);
  # A header argument replaces a default of the same name, whatever its case.
  for my $arg (UnivecUtilities::call_args($ctx, 'header')) {
    my (undef, $orig, $val) = @$arg;
    next unless defined $val;
    my $wire = lc $orig;
    delete $out->{$_} for grep { lc $_ eq $wire } keys %$out;
    $out->{$wire} = Voxgig::Struct::stringify($val);
  }
  # A cookie argument travels in the cookie header, form serialized and
  # percent-encoded, replacing a cookie of the same name among those the
  # caller's headers already send.
  my @sent = grep { defined $_->[2] } UnivecUtilities::call_args($ctx, 'cookie');
  if (@sent) {
    my %names = map {
      my $arg = $_;
      map { ($_ => 1) } (Voxgig::Struct::ismap($arg->[2])
        ? (map { Voxgig::Struct::escurl($_) } @{ Voxgig::Struct::keysof($arg->[2]) }) : ($arg->[1]));
    } @sent;
    my @kept;
    for my $key (grep { lc $_ eq 'cookie' } keys %$out) {
      my $given = delete $out->{$key};
      next if !defined $given || ref $given;
      push @kept, @{ cookie_keep($given, \%names) };
    }
    for my $arg (@sent) {
      my $pair = UnivecUtilities::cookie_pair($arg->[1], $arg->[2]);
      push @kept, $pair if $pair ne '';
    }
    $out->{cookie} = join('; ', @kept) if @kept;
  }
  return $out;
};

# The caller's cookie pieces with the named cookies removed: a cookie is one
# ;-delimited piece, whatever its value holds.
sub cookie_keep {
  my ($header, $names) = @_;
  my @kept;
  for my $piece (split /;/, $header) {
    (my $cookie = $piece) =~ s/^\s+|\s+$//g;
    next if $cookie eq '';
    (my $name = (split /=/, $cookie, 2)[0]) =~ s/^\s+|\s+$//g;
    push @kept, $cookie unless $names->{$name};
  }
  return \@kept;
}

# The form style of a cookie parameter: a list repeats the name, a map sends
# its own keys, and every value is percent-encoded.
sub cookie_pair {
  my ($wire, $val) = @_;
  my $esc = sub { Voxgig::Struct::escurl(Voxgig::Struct::stringify($_[0])) };
  my @pairs;
  if (Voxgig::Struct::islist($val)) {
    @pairs = map { $wire . '=' . $esc->($_) } @$val;
  }
  elsif (Voxgig::Struct::ismap($val)) {
    @pairs = map { Voxgig::Struct::escurl($_) . '=' . $esc->($val->{$_}) } @{ Voxgig::Struct::keysof($val) };
  }
  else {
    @pairs = ($wire . '=' . $esc->($val));
  }
  return join('; ', @pairs);
}

1;
