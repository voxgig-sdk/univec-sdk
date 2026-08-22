# ProjectName SDK

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

package ProjectNameSDK;

our $VERSION = '0.0.1';

our $DIR;
BEGIN { $DIR = File::Basename::dirname(Cwd::abs_path(__FILE__)) }

require(Cwd::abs_path("$DIR/Voxgig/Struct.pm"));
require(Cwd::abs_path("$DIR/../core/helpers.pm"));
require(Cwd::abs_path("$DIR/../core/utility_type.pm"));
require(Cwd::abs_path("$DIR/../core/spec.pm"));
require(Cwd::abs_path("$DIR/../core/error.pm"));

# Load utility registration
require(Cwd::abs_path("$DIR/../utility/register.pm"));

# Load config and features
require(Cwd::abs_path("$DIR/../config.pm"));
require(Cwd::abs_path("$DIR/../feature/base_feature.pm"));
require(Cwd::abs_path("$DIR/../features.pm"));

sub new {
  my ($class, $options) = @_;
  $options = {} unless defined $options;

  my $self = bless {
    mode => 'live',
    features => [],
    options => undef,
  }, $class;

  my $utility = ProjectNameUtility->new;
  $self->{_utility} = $utility;

  # The process-wide config (sdkgen rung L2): read-only on the request path,
  # so every client shares one rather than rebuilding it.
  my $config = ProjectNameConfig::shared_config();

  $self->{_rootctx} = $utility->{make_context}->({
    'client' => $self,
    'utility' => $utility,
    'config' => $config,
    'options' => $options,
    'shared' => {},
  }, undef);

  $self->{options} = $utility->{make_options}->($self->{_rootctx});

  if (ProjectNameHelpers::is_true(
    ProjectNameHelpers::gpath($self->{options}, 'feature.test.active'))) {
    $self->{mode} = 'test';
  }

  $self->{_rootctx}{options} = $self->{options};

  # Add features in the resolved order (make_options records an explicit
  # array order, else defaults to test-first). Ordering matters: the `test`
  # feature installs the base mock transport and the transport features
  # (retry/cache/netsim/proxy/ratelimit) wrap whatever is current, so `test`
  # must be added before them to sit at the base of the wrapper chain.
  my $feature_opts = ProjectNameHelpers::to_map(
    ProjectNameHelpers::gp($self->{options}, 'feature')) || {};
  my $featureorder = ProjectNameHelpers::gpath(
    $self->{options}, '__derived__.featureorder');
  $featureorder = [] unless Voxgig::Struct::islist($featureorder);
  for my $fname (@$featureorder) {
    my $fopts = ProjectNameHelpers::to_map($feature_opts->{$fname});
    if ($fopts && ProjectNameHelpers::is_true($fopts->{active})) {
      $utility->{feature_add}->($self->{_rootctx},
        ProjectNameFeatures::make_feature($fname));
    }
  }

  # Add extension features.
  my $extend = ProjectNameHelpers::gp($self->{options}, 'extend');
  if (Voxgig::Struct::islist($extend)) {
    for my $f (@$extend) {
      if (Scalar::Util::blessed($f) && $f->can('get_name')) {
        $utility->{feature_add}->($self->{_rootctx}, $f);
      }
    }
  }

  # Initialize features.
  for my $f (@{ $self->{features} }) {
    $utility->{feature_init}->($self->{_rootctx}, $f);
  }

  $utility->{feature_hook}->($self->{_rootctx}, 'PostConstruct');

  return $self;
}

sub options_map {
  my ($self) = @_;
  my $out = Voxgig::Struct::clone($self->{options});
  return Voxgig::Struct::ismap($out) ? $out : {};
}

sub get_utility {
  my ($self) = @_;
  return ProjectNameUtility->copy($self->{_utility});
}

sub get_root_ctx {
  my ($self) = @_;
  return $self->{_rootctx};
}

sub prepare {
  my ($self, $fetchargs) = @_;
  my $utility = $self->{_utility};
  $fetchargs = {} unless defined $fetchargs;

  my $ctrl = ProjectNameHelpers::to_map(
    ProjectNameHelpers::gp($fetchargs, 'ctrl')) || {};

  my $ctx = $utility->{make_context}->({
    'opname' => 'prepare',
    'ctrl' => $ctrl,
  }, $self->{_rootctx});

  my $opts = $self->{options};
  my $path = ProjectNameHelpers::gp($fetchargs, 'path');
  $path = '' unless defined $path && !ref $path;
  my $method_val = ProjectNameHelpers::gp($fetchargs, 'method');
  $method_val = 'GET' unless defined $method_val && !ref $method_val;
  my $params = ProjectNameHelpers::to_map(
    ProjectNameHelpers::gp($fetchargs, 'params')) || {};
  my $query = ProjectNameHelpers::to_map(
    ProjectNameHelpers::gp($fetchargs, 'query')) || {};
  my $headers = $utility->{prepare_headers}->($ctx);

  my $base = ProjectNameHelpers::gp($opts, 'base');
  $base = '' unless defined $base && !ref $base;
  my $prefix = ProjectNameHelpers::gp($opts, 'prefix');
  $prefix = '' unless defined $prefix && !ref $prefix;
  my $suffix = ProjectNameHelpers::gp($opts, 'suffix');
  $suffix = '' unless defined $suffix && !ref $suffix;

  $ctx->{spec} = ProjectNameSpec->new({
    'base' => $base, 'prefix' => $prefix, 'suffix' => $suffix,
    'path' => $path, 'method' => $method_val,
    'params' => $params, 'query' => $query, 'headers' => $headers,
    'body' => ProjectNameHelpers::gp($fetchargs, 'body'),
    'step' => 'start',
  });

  # Merge user-provided headers.
  my $uh = ProjectNameHelpers::gp($fetchargs, 'headers');
  if (Voxgig::Struct::ismap($uh)) {
    $ctx->{spec}{headers}{$_} = $uh->{$_} for keys %$uh;
  }

  my (undef, $err) = $utility->{prepare_auth}->($ctx);
  die $err if $err;

  # make_fetch_def returns a (fetchdef, err) tuple; destructure it and
  # return just the fetchdef hashref (dying on error) so callers -
  # including direct(), which indexes fetchdef->{url} - receive a hashref,
  # mirroring the ts/py/rb prepare().
  my ($fetchdef, $fd_err) = $utility->{make_fetch_def}->($ctx);
  die $fd_err if $fd_err;

  return $fetchdef;
}

# Raw endpoint access is operator-controllable, like every entity op.
# Blocking it means denying BOTH the 'direct' and 'graphql' tokens, since
# either one reaches the same endpoint.
sub direct {
  my ($self, $fetchargs) = @_;

  return $self->_op_denied('direct') unless $self->_op_allowed('direct');

  return $self->_raw_request($fetchargs);
}

# Is this raw-access op permitted by the SDK's allow.op option?
sub _op_allowed {
  my ($self, $op) = @_;
  my $allow = ProjectNameHelpers::gpath($self->{options}, 'allow.op');
  return (defined $allow && !ref $allow && index($allow, $op) >= 0) ? 1 : 0;
}

sub _op_denied {
  my ($self, $op) = @_;
  my $allow = ProjectNameHelpers::gpath($self->{options}, 'allow.op');
  $allow = '' unless defined $allow && !ref $allow;
  return {
    'ok' => 0,
    'err' => "ProjectNameSDK: $op: operation not allowed by" .
      " SDK option allow.op value: \"$allow\"",
  };
}

# Ungated request path shared by direct and graphql, each of which checks its
# own allow.op token first. Private, rather than a flag on fetchargs: a
# caller-supplied marker would let anyone opt straight back out of the gate
# by passing it.
sub _raw_request {
  my ($self, $fetchargs) = @_;
  my $utility = $self->{_utility};

  # direct() is the raw-HTTP escape hatch: it always returns a result hash
  # ({ ok => ..., ... }) and never dies. prepare() dies on error, so trap
  # that and surface it in the hash.
  my $fetchdef = eval { $self->prepare($fetchargs) };
  if (my $prep_err = $@) {
    return { 'ok' => 0, 'err' => $prep_err };
  }

  $fetchargs = {} unless defined $fetchargs;
  my $ctrl = ProjectNameHelpers::to_map(
    ProjectNameHelpers::gp($fetchargs, 'ctrl')) || {};

  my $ctx = $utility->{make_context}->({
    'opname' => 'direct',
    'ctrl' => $ctrl,
  }, $self->{_rootctx});

  my $url = defined $fetchdef->{url} ? $fetchdef->{url} : '';
  my ($fetched, $fetch_err) = $utility->{fetcher}->($ctx, $url, $fetchdef);

  return { 'ok' => 0, 'err' => $fetch_err } if $fetch_err;

  if (!defined $fetched) {
    return {
      'ok' => 0,
      'err' => $ctx->make_error('direct_no_response', 'response: undefined'),
    };
  }

  if (Voxgig::Struct::ismap($fetched)) {
    my $status = ProjectNameHelpers::to_int(
      ProjectNameHelpers::gp($fetched, 'status'));
    my $headers = ProjectNameHelpers::gp($fetched, 'headers') || {};

    # No-body responses (204, 304) and explicit zero content-length must
    # skip JSON parsing - calling json() on an empty body errors.
    my $content_length = Voxgig::Struct::ismap($headers)
      ? $headers->{'content-length'} : undef;
    my $no_body = (204 == $status || 304 == $status
      || (defined $content_length && '0' eq "$content_length")) ? 1 : 0;

    my $json_data;
    unless ($no_body) {
      my $jf = ProjectNameHelpers::gp($fetched, 'json');
      if (ref $jf eq 'CODE') {
        # Non-JSON body - leave data undef, keep status/headers.
        $json_data = eval { $jf->() };
      }
    }

    return {
      'ok' => ($status >= 200 && $status < 300) ? 1 : 0,
      'status' => $status,
      'headers' => $headers,
      'data' => $json_data,
    };
  }

  return {
    'ok' => 0,
    'err' => $ctx->make_error('direct_invalid', 'invalid response type'),
  };
}

# Raw GraphQL access: the pressure valve that makes the generated surface's
# deliberate omissions (per-call selection sets, typed filter builders,
# batching, subscriptions) livable — the whole schema stays reachable.
#
# Thin wrapper over the same prepare/fetch path direct uses, with the one
# thing raw direct cannot do for GraphQL: a GraphQL failure rides HTTP 200 as
# a top-level `errors` array, so status alone would report a failed query as
# ok.
#
# NOTE: like direct, this bypasses the feature pipeline — no retry, ratelimit
# or paging features apply.
sub graphql {
  my ($self, $query, $variables, $ctrl) = @_;

  return $self->_op_denied('graphql') unless $self->_op_allowed('graphql');

  my $res = $self->_raw_request({
    'method' => 'POST',
    'headers' => { 'content-type' => 'application/json' },
    'body' => {
      'query' => defined $query ? $query : '',
      'variables' => (ref $variables eq 'HASH') ? $variables : {},
    },
    'ctrl' => (ref $ctrl eq 'HASH') ? $ctrl : {},
  });

  return $res unless ref $res eq 'HASH';

  # Errors are read BEFORE any status check: a GraphQL parse or validation
  # failure comes back as HTTP 400 carrying the standard { errors: [...] }
  # body, and the raw path represents a non-2xx as ok:0 with no err — so
  # returning early on status would discard the server's own diagnostics,
  # which are the only useful part of that response.
  my $errors = ProjectNameHelpers::gpath($res, 'data.errors');

  if (ref $errors eq 'ARRAY' && 0 < scalar @$errors) {
    my $first = $errors->[0];
    my $msg = (ref $first eq 'HASH') ? $first->{'message'} : undef;
    $msg = 'graphql error' unless defined $msg && $msg ne '';
    $res->{'ok'} = 0;
    $res->{'err'} = "ProjectNameSDK: graphql: $msg";
    $res->{'graphql'} = $errors;
  }

  return $res;
}

# <[SLOT]>

sub test {
  my ($class, $testopts, $sdkopts) = @_;
  $sdkopts = {} unless defined $sdkopts;
  $sdkopts = Voxgig::Struct::clone($sdkopts);
  $sdkopts = {} unless Voxgig::Struct::ismap($sdkopts);

  $testopts = {} unless defined $testopts;
  $testopts = Voxgig::Struct::clone($testopts);
  $testopts = {} unless Voxgig::Struct::ismap($testopts);
  $testopts->{active} = Voxgig::Struct::JTRUE();

  Voxgig::Struct::setpath($sdkopts, 'feature.test', $testopts);

  my $sdk = $class->new($sdkopts);
  $sdk->{mode} = 'test';
  return $sdk;
}

1;
