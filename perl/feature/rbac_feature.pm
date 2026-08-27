# Univec SDK rbac feature
#
# Client-side role/permission enforcement. Before an operation resolves its
# endpoint, the required permission for that entity+operation is checked
# against the permissions the client holds; a disallowed call is
# short-circuited with an "rbac_denied" error and never touches the
# network. Required permissions come from "rules" (keyed by
# "<entity>.<op>", "<op>", or "*"); the default when no rule matches is
# controlled by "deny" (default: allow when unspecified). Held permissions
# are the "permissions" list (a "*" grants everything).

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecRbacFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'rbac';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{granted} = {};
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});

  $self->{granted} = {};
  my $perms = $self->{options}{permissions};
  if (Voxgig::Struct::islist($perms)) {
    $self->{granted}{"$_"} = 1 for @$perms;
  }
  return;
}

sub PrePoint {
  my ($self, $ctx) = @_;
  return unless $self->{active};

  my $required = $self->_required($ctx);
  if (!defined $required) {
    # No rule: honour the default policy.
    return $self->_reject($ctx, '<default-deny>')
      if UnivecHelpers::is_true($self->{options}{deny});
    return;
  }

  if ($self->{granted}{'*'} || $self->{granted}{$required}) {
    $self->_track($ctx, $required, 1);
    return;
  }

  $self->_reject($ctx, $required);
  return;
}

sub _required {
  my ($self, $ctx) = @_;
  my $rules = $self->{options}{rules} || {};
  my $entity = '';
  if ($ctx->{entity} && Scalar::Util::blessed($ctx->{entity})
    && $ctx->{entity}->can('get_name')) {
    $entity = $ctx->{entity}->get_name;
  }
  elsif ($ctx->{op}) {
    $entity = $ctx->{op}{entity};
  }
  my $opname = $ctx->{op} ? $ctx->{op}{name} : '';

  return $rules->{"$entity.$opname"} if defined $rules->{"$entity.$opname"};
  return $rules->{$opname} if defined $rules->{$opname};
  return $rules->{'*'} if defined $rules->{'*'};
  return undef;
}

sub _reject {
  my ($self, $ctx, $required) = @_;
  $self->_track($ctx, $required, 0);
  my $opname = ($ctx->{op} && '' ne $ctx->{op}{name}) ? $ctx->{op}{name} : '?';
  my $err = $ctx->make_error('rbac_denied',
    "Permission \"$required\" required for operation \"$opname\"");
  # Short-circuit endpoint resolution; make_point surfaces this error
  # before any network use.
  $ctx->{out}{point} = $err;
  return $err;
}

sub _track {
  my ($self, $ctx, $required, $allowed) = @_;
  my $track = $self->{client}{_rbac};
  if (!$track) {
    $track = { 'allowed' => 0, 'denied' => 0, 'last' => undef };
    $self->{client}{_rbac} = $track;
  }
  $track->{ $allowed ? 'allowed' : 'denied' } += 1;
  $track->{last} = {
    'required' => $required,
    'allowed' => $allowed ? Voxgig::Struct::JTRUE() : Voxgig::Struct::JFALSE(),
    'op' => ($ctx->{op} ? $ctx->{op}{name} : undef),
  };
  return;
}

1;
