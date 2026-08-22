# EJECT-START

# Load a single EntityName.
#
# reqmatch: match criteria hashref (id/query fields; EntityNameLoadMatch
# shape); optional - an entity with no id-like key loads with no match
# (undef is treated as an empty match). ctrl: optional per-call control.
# Returns the loaded EntityName data (hashref); dies with ProjectNameError
# on failure.
sub load {
  my ($self, $reqmatch, $ctrl) = @_;
  my $utility = $self->{_utility};
  my $ctx = $utility->{make_context}->({
    'opname' => 'load',
    'ctrl' => $ctrl,
    'match' => $self->{_match},
    'data' => $self->{_data},
    'reqmatch' => $reqmatch,
  }, $self->{_entctx});

  return $self->_run_op($ctx, sub {
    my $result = $ctx->{result};
    if ($result) {
      $self->{_match} = $result->{resmatch} if $result->{resmatch};
      if ($result->{resdata}) {
        $self->{_data} = ProjectNameHelpers::to_map(
          Voxgig::Struct::clone($result->{resdata})) || {};
      }
    }
    return;
  });
}

# EJECT-END
