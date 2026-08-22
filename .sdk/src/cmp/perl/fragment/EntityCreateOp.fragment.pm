# EJECT-START

# Create a new EntityName.
#
# reqdata: body data hashref (EntityNameCreateData shape). ctrl: optional
# per-call control. Returns the created EntityName data (hashref); dies
# with ProjectNameError on failure.
sub create {
  my ($self, $reqdata, $ctrl) = @_;
  my $utility = $self->{_utility};
  my $ctx = $utility->{make_context}->({
    'opname' => 'create',
    'ctrl' => $ctrl,
    'match' => $self->{_match},
    'data' => $self->{_data},
    'reqdata' => $reqdata,
  }, $self->{_entctx});

  return $self->_run_op($ctx, sub {
    my $result = $ctx->{result};
    if ($result) {
      if ($result->{resdata}) {
        $self->{_data} = ProjectNameHelpers::to_map(
          Voxgig::Struct::clone($result->{resdata})) || {};
      }
    }
    return;
  });
}

# EJECT-END
