# Univec SDK utility: make_url

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{make_url} = sub {
  my ($ctx) = @_;
  my $spec = $ctx->{spec};
  my $result = $ctx->{result};

  return ('', $ctx->make_error('url_no_spec',
    'Expected context spec property to be defined.')) unless $spec;
  return ('', $ctx->make_error('url_no_result',
    'Expected context result property to be defined.')) unless $result;

  my $url = Voxgig::Struct::join(
    [$spec->{base}, $spec->{prefix}, $spec->{path}, $spec->{suffix}], '/', 1);
  my $resmatch = {};

  # Sent with the request, never recorded as the entity's match.
  my %authquery = map { $_ => 1 } @{ $spec->{authquery} || [] };

  # A route the definition ends with a slash keeps it: a server such as a
  # Django REST one redirects or refuses the route without it.
  my $orig = $ctx->{point} ? UnivecHelpers::gp($ctx->{point}, 'orig') : undef;
  $url .= '/' if defined $orig && !ref $orig && $orig =~ m{/\z}
    && !(defined $spec->{suffix} && '' ne $spec->{suffix}) && $url !~ m{/\z};

  my $param_items = Voxgig::Struct::items($spec->{params});
  if ($param_items) {
    for my $item (@$param_items) {
      my ($key, $val) = @$item;
      if (UnivecHelpers::rb_truthy($val) && defined $key && !ref $key) {
        my $placeholder = '{' . $key . '}';
        my $encoded = Voxgig::Struct::escurl("$val");
        $url =~ s/\Q$placeholder\E/$encoded/g;
        $resmatch->{$key} = $val;
      }
    }
  }

  # A placeholder left in the route would send the request to the wrong route.
  # The base's own placeholders are server variables, resolved with the options.
  my $base = defined $spec->{base} && !ref $spec->{base} ? $spec->{base} : '';
  $base =~ s{/+\z}{};
  my $route = 0 == index($url, $base) ? substr($url, length $base) : $url;
  my @unfilled = $route =~ /(\{[^{}\/]+\})/g;
  return ('', $ctx->make_error('url_param_missing',
    'URL path has no value for ' . join(', ', @unfilled) . '.')) if @unfilled;

  # Append query string from spec.query.
  my $qsep = '?';
  my $query_items = Voxgig::Struct::items($spec->{query});
  if ($query_items) {
    for my $item (@$query_items) {
      my ($key, $val) = @$item;
      if (UnivecHelpers::rb_truthy($val) && defined $key && !ref $key) {
        $url .= $qsep . Voxgig::Struct::escurl("$key") . '=' . Voxgig::Struct::escurl("$val");
        $qsep = '&';
        $resmatch->{$key} = $val unless $authquery{$key};
      }
    }
  }

  $result->{resmatch} = $resmatch;
  return ($url, undef);
};

1;
