# EJECT-START

# Update an existing EntityName.
#
# reqdata: body data hashref (EntityNameUpdateData shape). ctrl: optional
# per-call control. Returns the updated EntityName data (hashref); dies
# with ProjectNameError on failure.
sub update {
  my ($self, $reqdata, $ctrl) = @_;
  my $utility = $self->{_utility};
  my $ctx = $utility->{make_context}->({
    'opname' => 'update',
    'ctrl' => $ctrl,
    'match' => $self->{_match},
    'data' => $self->{_data},
    'reqdata' => $reqdata,
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
