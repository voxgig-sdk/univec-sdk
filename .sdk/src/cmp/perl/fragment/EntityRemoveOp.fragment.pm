# EJECT-START

# Remove an EntityName matching the given criteria.
#
# reqmatch: match criteria hashref (id/query fields; EntityNameRemoveMatch
# shape). ctrl: optional per-call control. Returns the removed EntityName
# data (hashref); dies with ProjectNameError on failure.
sub remove {
  my ($self, $reqmatch, $ctrl) = @_;
  my $utility = $self->{_utility};
  my $ctx = $utility->{make_context}->({
    'opname' => 'remove',
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
