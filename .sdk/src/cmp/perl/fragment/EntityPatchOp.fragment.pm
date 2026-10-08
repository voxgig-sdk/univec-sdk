# EJECT-START

# Change part of an existing EntityName: only the fields given are sent.
#
# reqdata: body data hashref (EntityNamePatchData shape). ctrl: optional
# per-call control. Returns the patched EntityName entity (data_get reads
# its record); dies with ProjectNameError on failure.
sub patch {
  my ($self, $reqdata, $ctrl) = @_;
  my $utility = $self->{_utility};
  my $ctx = $utility->{make_context}->({
    'opname' => 'patch',
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
