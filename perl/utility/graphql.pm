# Univec SDK utility: graphql
#
# GraphQL transport. API-INDEPENDENT: every GraphQL SDK this generator
# produces uses this file unchanged. The API-specific part — which
# operations exist and what each one's document is — is model data,
# computed once by apidef and emitted into Config.
#
# Two jobs:
#
#   graphql_body   — build { query, variables } for a point, binding the
#                    op's arguments to the document's declared variables.
#
#   graphql_errors — lift a GraphQL failure into an SDK error. GraphQL
#                    reports failures as a top-level `errors` array under
#                    HTTP 200, so the status-driven path in result_basic
#                    never sees them.

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

# Content type every GraphQL-over-HTTP request uses.
our $GRAPHQL_CONTENT_TYPE = 'application/json';

# Map a GraphQL error to the same error codes the HTTP path produces, so a
# caller handles auth or rate limiting identically on both transports.
# Servers put the machine-readable code in `extensions.code`; Linear-style
# APIs use `extensions.type`.
sub graphql_error_code {
  my ($gqlerr) = @_;

  my $ext = UnivecHelpers::gp($gqlerr, 'extensions');

  my $raw = UnivecHelpers::gp($ext, 'code');
  $raw = UnivecHelpers::gp($ext, 'type') if !defined $raw || '' eq $raw;
  $raw = defined $raw ? uc("$raw") : '';

  return 'request_auth'
    if $raw =~ /AUTH/ || $raw =~ /FORBIDDEN/ || $raw =~ /UNAUTHENTICATED/;
  return 'request_ratelimit'
    if $raw =~ /RATELIMIT/ || $raw =~ /RATE_LIMIT/ || $raw =~ /TOO_MANY/;
  return 'request_invalid'
    if $raw =~ /BAD_USER_INPUT/ || $raw =~ /VALIDATION/ || $raw =~ /INVALID/;

  return 'request_graphql';
}

# Build the request body for a GraphQL point.
#
# Variables come from the op's own arguments: a named variable binds to the
# like-named argument (`from`), and the input-object variable (empty
# `from`) takes the request data as a whole — which is what makes a
# generated create/update call look exactly like its REST equivalent.
$REGISTRY{graphql_body} = sub {
  my ($ctx) = @_;

  my $gql = UnivecHelpers::gp($ctx->{point}, 'graphql');
  return undef unless ref($gql) eq 'HASH';

  # reqmatch/reqdata hold the caller's arguments for THIS call; data/match
  # hold the entity's current state. Which pair depends on whether the op
  # takes match or data input. A named variable falls back to the current
  # state, so updating a loaded entity with just {title} still binds the
  # stored id the mutation requires.
  my $datainput =
    $ctx->{op} && defined $ctx->{op}{input} && 'data' eq $ctx->{op}{input};
  my $reqsrc = $datainput ? $ctx->{reqdata} : $ctx->{reqmatch};
  my $datasrc = $datainput ? $ctx->{data} : $ctx->{match};
  $reqsrc = {} unless ref($reqsrc) eq 'HASH';
  $datasrc = {} unless ref($datasrc) eq 'HASH';

  my %variables;

  my $varlist = UnivecHelpers::gp($gql, 'vars');
  $varlist = [] unless ref($varlist) eq 'ARRAY';

  for my $spec (@$varlist) {
    next unless ref($spec) eq 'HASH';

    my $name = UnivecHelpers::gp($spec, 'name');
    my $from = UnivecHelpers::gp($spec, 'from');
    next unless defined $name;

    if (!defined $from || '' eq $from) {
      # The input object IS the request body. Strip the action selector,
      # which is an SDK-side point discriminator, not an API field.
      my %body;
      for my $k (keys %$reqsrc) {
        $body{$k} = $reqsrc->{$k} unless '$action' eq $k;
      }
      $variables{$name} = \%body;
      next;
    }

    # Only send variables the caller actually supplied: sending an explicit
    # null would clear a field on many APIs.
    my $val = UnivecHelpers::gp($reqsrc, $from);
    $val = UnivecHelpers::gp($datasrc, $from) unless defined $val;
    $variables{$name} = $val if defined $val;
  }

  return {
    query     => UnivecHelpers::gp($gql, 'doc'),
    variables => \%variables,
  };
};

# Inspect a decoded GraphQL response body and record a failure when the
# server reported one. Returns true when an error was recorded.
#
# Partial data (`data` alongside `errors`) is treated as failure: the REST
# surface has no partial-success concept, and silently returning half an
# object would be worse than failing.
$REGISTRY{graphql_errors} = sub {
  my ($ctx) = @_;

  my $result = $ctx->{result};
  return 0 unless $result && $ctx->{point};

  my $kind = UnivecHelpers::gp($ctx->{point}, 'kind');
  return 0 unless defined $kind && 'graphql' eq $kind;

  my $errors = UnivecHelpers::gp($result->{body}, 'errors');
  return 0 unless ref($errors) eq 'ARRAY' && 0 < scalar(@$errors);

  my $first = $errors->[0];
  my $msg = UnivecHelpers::gp($first, 'message');
  $msg = 'graphql error' unless defined $msg && '' ne $msg;
  $msg = $msg . ' (+' . (scalar(@$errors) - 1) . ' more)'
    if 1 < scalar(@$errors);

  $result->{err} =
    $ctx->make_error(graphql_error_code($first), 'graphql: ' . $msg);
  $result->{ok} = 0;

  return 1;
};

1;
