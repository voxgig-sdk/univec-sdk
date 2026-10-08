# EJECT-START

# List EntityName items matching the given filter.
#
# reqmatch: match filter hashref (any subset of EntityName fields;
# EntityNameListMatch shape); defaults to undef, treated as an empty match
# that lists all. ctrl: optional per-call control.
# Returns the matching EntityName items as an arrayref of entities, one per
# record (data_get reads the record); dies with ProjectNameError on failure.
sub list {
  my ($self, $reqmatch, $ctrl) = @_;
  my $utility = $self->{_utility};
  my $ctx = $utility->{make_context}->({
    'opname' => 'list',
    'ctrl' => $ctrl,
    'match' => $self->{_match},
    'data' => $self->{_data},
    'reqmatch' => $reqmatch,
  }, $self->{_entctx});

  my $records = $self->_run_op($ctx, sub {
    my $result = $ctx->{result};
    if ($result) {
      $self->{_match} = $result->{resmatch} if $result->{resmatch};
    }
    return;
  });

  return $records;
}

# EJECT-END
