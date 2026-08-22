# Univec SDK utility: make_point

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use Scalar::Util ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/../core/error.pm"));

package UnivecUtilities;

our %REGISTRY;

# How many path segments a point has.
sub _parts_len {
  my ($point) = @_;
  my $parts = UnivecHelpers::gp($point, 'parts');
  return Voxgig::Struct::islist($parts) ? scalar(@$parts) : 0;
}

# Does this point's path end in a parameter? A record route ends in the
# record's identifier (/boards/{id}); a cross-reference that also returns the
# entity ends in the relationship's name (/posts/{id}/author). That, then
# fewest segments, is what tells the entity's own route from a
# cross-reference. The same rule runs at generation time, in
# helpers/opShape.ts — both sides must move together.
sub _terminal_param {
  my ($point) = @_;
  my $parts = UnivecHelpers::gp($point, 'parts');
  return 0 unless Voxgig::Struct::islist($parts) && 0 < scalar(@$parts);
  my $last = $parts->[-1];
  return (defined $last && !ref $last && $last =~ /^\{/) ? 1 : 0;
}

$REGISTRY{make_point} = sub {
  my ($ctx) = @_;

  if ($ctx->{out}{point}) {
    my $preset = $ctx->{out}{point};
    # A feature may short-circuit endpoint resolution by placing an error
    # in ctx.out.point (e.g. an rbac denial): surface it as the error
    # tuple slot so the operation fails before any network use.
    return (undef, $preset)
      if Scalar::Util::blessed($preset) && $preset->isa('UnivecError');
    $ctx->{point} = $preset;
    return ($ctx->{point}, undef);
  }

  my $op = $ctx->{op};
  my $options = $ctx->{options};

  my $allow_op = UnivecHelpers::gpath($options, 'allow.op');
  $allow_op = '' unless defined $allow_op && !ref $allow_op;
  if (index($allow_op, $op->{name}) < 0) {
    return (undef, $ctx->make_error('point_op_allow',
      "Operation \"$op->{name}\" not allowed by SDK option allow.op value: \"$allow_op\""));
  }

  if (!@{ $op->{points} }) {
    return (undef, $ctx->make_error('point_no_points',
      "Operation \"$op->{name}\" has no endpoint definitions."));
  }

  if (1 == @{ $op->{points} }) {
    $ctx->{point} = $op->{points}[0];
  }
  else {
    my $reqselector = ('data' eq $op->{input}) ? $ctx->{reqdata} : $ctx->{reqmatch};
    my $selector = ('data' eq $op->{input}) ? $ctx->{data} : $ctx->{match};

    my $point;
    my $matched = 0;
    for my $p (@{ $op->{points} }) {
      my $select_def = UnivecHelpers::to_map(UnivecHelpers::gp($p, 'select'));
      my $found = 1;

      if ($selector && $select_def) {
        my $exist = UnivecHelpers::gp($select_def, 'exist');
        if (Voxgig::Struct::islist($exist)) {
          for my $ek (@$exist) {
            my $rv = UnivecHelpers::gp($reqselector, "$ek");
            my $sv = UnivecHelpers::gp($selector, "$ek");
            if (!defined $rv && !defined $sv) {
              $found = 0;
              last;
            }
          }
        }
      }

      if ($found) {
        my $req_action = UnivecHelpers::gp($reqselector, '$action');
        my $select_action = UnivecHelpers::gp($select_def, '$action');
        $found = 0 unless UnivecHelpers::eqv($req_action, $select_action);
      }

      if ($found) {
        $point = $p;
        $matched = 1;
        last;
      }
    }

    # select.exist can list more than the params needed to pick a point, so
    # nothing matches — fall back to the entity's own route rather than
    # whichever point came last.
    unless ($matched) {
      # A request naming an action reaches here only because that action's
      # own point failed its exist test, so it is unbuildable whatever we
      # pick. Refuse it BEFORE choosing a fallback: the guard below compares
      # the chosen point's $action and would wave the request through
      # whenever the fallback lands on the action point itself.
      my $unmatched_action = $reqselector
        ? UnivecHelpers::gp($reqselector, '$action') : undef;
      if (defined $unmatched_action) {
        return (undef, $ctx->make_error('point_action_invalid',
          'Operation "' . $op->{name} . '" action "' .
          Voxgig::Struct::stringify($unmatched_action) . '" is not valid.'));
      }

      $point = $op->{points}[0];
      for my $p (@{ $op->{points} }) {
        if (_terminal_param($p) != _terminal_param($point)) {
          $point = $p if _terminal_param($p);
        }
        elsif (_parts_len($p) < _parts_len($point)) {
          $point = $p;
        }
      }
    }

    if ($reqselector) {
      my $req_action = UnivecHelpers::gp($reqselector, '$action');
      if (defined $req_action && $point) {
        my $point_select = UnivecHelpers::to_map(UnivecHelpers::gp($point, 'select'));
        my $point_action = UnivecHelpers::gp($point_select, '$action');
        unless (UnivecHelpers::eqv($req_action, $point_action)) {
          return (undef, $ctx->make_error('point_action_invalid',
            "Operation \"$op->{name}\" action \""
            . Voxgig::Struct::stringify($req_action) . "\" is not valid."));
        }
      }
    }

    $ctx->{point} = $point;
  }

  return ($ctx->{point}, undef);
};

1;
