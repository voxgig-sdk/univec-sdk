# ProjectName SDK EntityName entity

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package EntyClass;

sub new {
  my ($class, $client, $entopts) = @_;
  $entopts = {} unless defined $entopts;
  if (!defined $entopts->{active}) {
    $entopts->{active} = Voxgig::Struct::JTRUE();
  }
  elsif (ProjectNameHelpers::is_false($entopts->{active})) {
    # keep false
  }
  else {
    $entopts->{active} = Voxgig::Struct::JTRUE();
  }

  my $self = bless {
    _name => 'entityname',
    _client => $client,
    _utility => $client->get_utility,
    _entopts => $entopts,
    _data => {},
    _deleted => 0,
    _match => {},
  }, $class;

  $self->{_entctx} = $self->{_utility}{make_context}->({
    'entity' => $self,
    'entopts' => $entopts,
  }, $client->get_root_ctx);

  $self->{_utility}{feature_hook}->($self->{_entctx}, 'PostConstructEntity');

  return $self;
}

sub get_name {
  my ($self) = @_;
  return $self->{_name};
}

sub make {
  my ($self) = @_;
  my $opts = { %{ $self->{_entopts} } };
  return EntyClass->new($self->{_client}, $opts);
}

# Every operation resolves to the entity; `remove` additionally marks
# it. The instance KEEPS the data it held — a caller can still read what
# was deleted — but it is no longer a live record. See AGENTS.md.
sub mark_deleted {
  my ($self) = @_;
  $self->{_deleted} = 1;
  return $self;
}


sub deleted {
  my ($self) = @_;
  return $self->{_deleted} ? 1 : 0;
}


sub data_set {
  my ($self, $args) = @_;
  if ($args) {
    $self->{_data} = ProjectNameHelpers::to_map(Voxgig::Struct::clone($args)) || {};
    $self->{_utility}{feature_hook}->($self->{_entctx}, 'SetData');
  }
  return;
}

# Returns the current EntityName data (hashref).
sub data_get {
  my ($self) = @_;
  $self->{_utility}{feature_hook}->($self->{_entctx}, 'GetData');
  return Voxgig::Struct::clone($self->{_data});
}

sub match_set {
  my ($self, $args) = @_;
  if ($args) {
    $self->{_match} = ProjectNameHelpers::to_map(Voxgig::Struct::clone($args)) || {};
    $self->{_utility}{feature_hook}->($self->{_entctx}, 'SetMatch');
  }
  return;
}

# Returns the current match filter (any subset of EntityName fields).
sub match_get {
  my ($self) = @_;
  $self->{_utility}{feature_hook}->($self->{_entctx}, 'GetMatch');
  return Voxgig::Struct::clone($self->{_match});
}

# #LoadOp

# #ListOp

# #CreateOp

# #UpdateOp

# #RemoveOp

# Streaming operation. Runs `action` (an op name, e.g. 'list') through the
# full operation pipeline and returns an ITERATOR coderef: each call yields
# the next item (undef when exhausted), so the `streaming` feature's
# incremental output is reachable (a normal op call materialises the whole
# result). When the streaming feature is active the result carries a `stream`
# coderef and this yields from it (honouring chunkSize / chunkDelay); else it
# falls back to yielding the materialised items so stream() always yields.
# Yielded records are unwrapped to bare hashrefs (matching list()).
#
# $callopts parameterises the call:
#   - ctrl:   per-call pipeline control (threaded onto the op ctx);
#   - body:   an iterator coderef / arrayref payload for outbound (upload)
#             streaming - attached to the request (reqdata.body$ + a
#             stream_out marker on ctx) so the transport can stream it;
#   - signal: an optional coderef; when it returns true the iterator stops.
sub stream {
  my ($self, $action, $args, $callopts) = @_;
  my $utility = $self->{_utility};
  $callopts = ProjectNameHelpers::to_map($callopts) || {};
  my $signal = ProjectNameHelpers::gp($callopts, 'signal');
  my $ctrl = ProjectNameHelpers::to_map(
    ProjectNameHelpers::gp($callopts, 'ctrl')) || {};
  $ctrl->{stream} = $callopts;

  my $ctx = $utility->{make_context}->({
    'opname' => $action,
    'ctrl' => $ctrl,
    'match' => $self->{_match},
    'data' => $self->{_data},
    %{ ProjectNameHelpers::to_map($args) || {} },
  }, $self->{_entctx});

  # Outbound: expose an async-iterable/list payload so the request builder /
  # transport can stream it as the request body.
  my $body = ProjectNameHelpers::gp($callopts, 'body');
  if (defined $body) {
    my $reqdata = ProjectNameHelpers::to_map($ctx->{reqdata}) || {};
    $reqdata->{'body$'} = $body;
    $ctx->{reqdata} = $reqdata;
    $ctx->{stream_out} = $body;
  }

  $self->_run_op($ctx, sub { return });

  # Unwrap an Entity instance to its bare record; recurse into chunk arrays.
  my $unwrap;
  $unwrap = sub {
    my ($item) = @_;
    return $item unless defined $item;
    return $item->data_get
      if Scalar::Util::blessed($item) && $item->can('data_get');
    return [map { $unwrap->($_) } @$item] if Voxgig::Struct::islist($item);
    return $item;
  };

  my $aborted = sub {
    return (ref $signal eq 'CODE' && $signal->()) ? 1 : 0;
  };

  my $result = $ctx->{result};

  # Inbound: prefer the streaming feature's incremental iterator; else fall
  # back to the materialised items so stream() always yields.
  if ($result && ref $result->{stream} eq 'CODE') {
    my $src = $result->{stream};
    return sub {
      return undef if $aborted->();
      my $item = $src->();
      return undef unless defined $item;
      return $unwrap->($item);
    };
  }

  my $data = $result ? $result->{resdata} : undef;
  my @items = Voxgig::Struct::islist($data) ? @$data
    : (!defined $data ? () : ($data));
  @items = map { $unwrap->($_) } @items;
  return sub {
    return undef if $aborted->();
    return undef unless @items;
    return shift @items;
  };
}

sub _run_op {
  my ($self, $ctx, $post_done) = @_;
  my $utility = $self->{_utility};

  my $out = eval {
    # #PrePoint-Hook

    my ($point, $point_err) = $utility->{make_point}->($ctx);
    $ctx->{out}{point} = $point;
    return $utility->{make_error}->($ctx, $point_err) if $point_err;

    # #PreSpec-Hook

    my ($spec, $spec_err) = $utility->{make_spec}->($ctx);
    $ctx->{out}{spec} = $spec;
    return $utility->{make_error}->($ctx, $spec_err) if $spec_err;

    # #PreRequest-Hook

    my ($resp, $req_err) = $utility->{make_request}->($ctx);
    $ctx->{out}{request} = $resp;
    return $utility->{make_error}->($ctx, $req_err) if $req_err;

    # #PreResponse-Hook

    my ($resp2, $res_err) = $utility->{make_response}->($ctx);
    $ctx->{out}{response} = $resp2;
    return $utility->{make_error}->($ctx, $res_err) if $res_err;

    # #PreResult-Hook

    my ($result, $result_err) = $utility->{make_result}->($ctx);
    $ctx->{out}{result} = $result;
    return $utility->{make_error}->($ctx, $result_err) if $result_err;

    # #PreDone-Hook

    $post_done->();

    my $out = $utility->{done}->($ctx);

    # An operation resolves to the ENTITY, not the raw data. Entities are
    # stateful: post_done has just absorbed resdata/resmatch into this
    # instance, and the caller reaches the record through data(). Two
    # structural exceptions: `list` resolves to the ARRAY of entity
    # instances make_result built, and a failed op with throwing disabled
    # hands back the error payload unchanged. `remove` additionally marks
    # the entity deleted; it KEEPS its data, so a caller can still read
    # what was removed. See AGENTS.md "Entity operations return ENTITIES".
    my $opname = $ctx->{op} ? $ctx->{op}{name} : undef;

    if ($ctx->{result} && $ctx->{result}{ok}
      && (!defined $opname || $opname ne 'list')) {
      $self->mark_deleted if defined $opname && $opname eq 'remove';
      return $self;
    }

    $out;
  };
  if (my $operr = $@) {
    # #PreUnexpected-Hook

    die $operr;
  }
  return $out;
}

1;
