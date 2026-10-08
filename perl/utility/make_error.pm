# Univec SDK utility: make_error

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../core/context.pm"));
require(Cwd::abs_path("$__dir/../core/operation.pm"));
require(Cwd::abs_path("$__dir/../core/result.pm"));
require(Cwd::abs_path("$__dir/../core/error.pm"));
require(Cwd::abs_path("$__dir/clean.pm"));

package UnivecUtilities;

our %REGISTRY;

$REGISTRY{make_error} = sub {
  my ($ctx, $err) = @_;
  if (!defined $ctx) {
    $ctx = UnivecContext->new({}, undef);
  }
  my $op = $ctx->{op} || UnivecOperation->new({});
  my $opname = $op->{name};
  $opname = 'unknown operation' if !defined $opname || '' eq $opname || '_' eq $opname;

  my $result = $ctx->{result} || UnivecResult->new({});
  $result->{ok} = 0;

  $err = $result->{err} if !defined $err;
  $err = $ctx->make_error('unknown', 'unknown error') if !defined $err;

  # A bare context (no client, no utility) still cleans, through the
  # schema defaults.
  my $clean = ($ctx->{utility} && $ctx->{utility}{clean}) || $REGISTRY{clean};

  my $errmsg = (Scalar::Util::blessed($err) && $err->isa('UnivecError'))
    ? $err->{msg} : "$err";
  $errmsg =~ s/\s+\z//;
  my $msg = $clean->($ctx, "UnivecSDK: $opname: $errmsg");

  $result->{err} = undef;
  my $spec = $ctx->{spec};

  if ($ctx->{ctrl}{explain}) {
    $ctx->{ctrl}{explain}{err} = { 'message' => $msg };
  }

  # The context stays reachable for a debugger (`$err->ctx`) and is part of
  # no dump of the error; result and spec are cleaned COPIES, so masking
  # them never masks the pipeline's own objects.
  my $sdk_err = UnivecError->new('', $msg, $ctx);
  $sdk_err->{result} = $clean->($ctx, $result);
  $sdk_err->{spec} = $clean->($ctx, $spec);
  $sdk_err->{code} = $err->{code}
    if Scalar::Util::blessed($err) && $err->isa('UnivecError');

  # Promote the HTTP status to the top level, so a consumer can branch on
  # `$err->{status}` instead of reaching into `$err->{result}`.
  $sdk_err->{status} = defined $result->{status} ? $result->{status} : -1;

  $clean->($ctx, $sdk_err);

  $ctx->{ctrl}{err} = $sdk_err;

  # Fire PreUnexpected so observability features (metrics, telemetry, audit,
  # debug) close/record error paths that never reach PreDone (e.g. a PrePoint
  # rbac short-circuit). Fires after ctx.ctrl.err is set so hooks can read the
  # error; features guard against double-recording when PreDone already fired.
  if ($ctx->{utility} && $ctx->{utility}{feature_hook}) {
    $ctx->{utility}{feature_hook}->($ctx, 'PreUnexpected');
  }

  # Opt-out escape hatch: when throwing is explicitly disabled, return the
  # bare result data instead of dying.
  if (defined $ctx->{ctrl}{throw_err} && !$ctx->{ctrl}{throw_err}) {
    return $result->{resdata};
  }
  # Default idiomatic path: die with the already-constructed exception.
  die $sdk_err;
};

1;
