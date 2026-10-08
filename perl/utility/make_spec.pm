# Univec SDK utility: make_spec

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/../core/spec.pm"));
require(Cwd::abs_path("$__dir/prepare_method.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{make_spec} = sub {
  my ($ctx) = @_;

  if ($ctx->{out}{spec}) {
    my $preset = $ctx->{out}{spec};
    # A PreSpec hook (validate) rejects the operation by placing its error
    # here; the pipeline raises it, and ctx.spec stays a request spec.
    return (undef, $preset)
      if Scalar::Util::blessed($preset) && $preset->isa('UnivecError');
    $ctx->{spec} = $preset;
    return ($ctx->{spec}, undef);
  }

  my $point = $ctx->{point};
  my $options = $ctx->{options};
  my $utility = $ctx->{utility};

  my $base = UnivecHelpers::gp($options, 'base');
  $base = '' unless defined $base;
  my $prefix = UnivecHelpers::gp($options, 'prefix');
  $prefix = '' unless defined $prefix;
  my $suffix = UnivecHelpers::gp($options, 'suffix');
  $suffix = '' unless defined $suffix;

  my $parts = [];
  $parts = UnivecHelpers::gp($point, 'parts') if $point;
  $parts = [] unless Voxgig::Struct::islist($parts);

  $ctx->{spec} = UnivecSpec->new({
    'base' => $base, 'prefix' => $prefix, 'parts' => $parts,
    'suffix' => $suffix, 'step' => 'start',
  });

  $ctx->{spec}{method} = $utility->{prepare_method}->($ctx);

  my $allow_method = UnivecHelpers::gpath($options, 'allow.method');
  my $allow_ok = UnivecUtilities::allowed($allow_method, $ctx->{spec}{method});
  $allow_method = '' unless defined $allow_method && !ref $allow_method;
  unless ($allow_ok) {
    my $shown = $ctx->{spec}{method} // '';
    return (undef, $ctx->make_error('spec_method_allow',
      "Method \"$shown\" not allowed by SDK option allow.method value: \"$allow_method\""));
  }

  $ctx->{spec}{params} = $utility->{prepare_params}->($ctx);
  $ctx->{spec}{query} = $utility->{prepare_query}->($ctx);
  $ctx->{spec}{headers} = $utility->{prepare_headers}->($ctx);

  my $pkind = UnivecHelpers::gp($ctx->{point}, 'kind');
  if (defined $pkind && 'graphql' eq $pkind) {
    # GraphQL addresses one endpoint: no path parts, no query string, and
    # the body carries the operation. prepare_body is skipped deliberately
    # — it only emits a body for data-input ops, whereas every GraphQL op
    # posts one, including load/list/remove.
    $ctx->{spec}{body} = $utility->{graphql_body}->($ctx);
    $ctx->{spec}{path} = '';
    # prepare_query already copied the op's match arguments into the query
    # string. Those same values are bound as operation variables, so
    # leaving them would send /graphql?id=i1.
    $ctx->{spec}{query} = {};
    $ctx->{spec}{headers}{'content-type'} =
      $UnivecUtilities::GRAPHQL_CONTENT_TYPE;
  }
  else {
    $ctx->{spec}{body} = $utility->{prepare_body}->($ctx);
    $ctx->{spec}{path} = $utility->{prepare_path}->($ctx);
  }

  $ctx->{ctrl}{explain}{spec} = $ctx->{spec} if $ctx->{ctrl}{explain};

  # Whatever prepare_auth sets in the query, under whichever name, is the
  # credential; a key it leaves as it was is the caller's.
  my %query = %{ $ctx->{spec}{query} || {} };

  my ($spec, $err) = $utility->{prepare_auth}->($ctx);
  return (undef, $err) if $err;

  my $same = sub {
    my ($was, $now) = @_;
    return !defined $now unless defined $was;
    return 0 if !defined $now || ref $was ne ref $now;
    return ref $now ? $was == $now : $was eq $now;
  };
  my $now = $spec->{query} || {};
  $spec->{authquery} = [ grep {
    !exists $query{$_} || !$same->($query{$_}, $now->{$_})
  } sort keys %$now ];

  $ctx->{spec} = $spec;
  return ($spec, undef);
};

1;
