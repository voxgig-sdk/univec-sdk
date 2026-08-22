# EJECT-START

# List EntityName items matching the given filter.
#
# reqmatch: match filter hashref (any subset of EntityName fields;
# EntityNameListMatch shape); defaults to undef, treated as an empty match
# that lists all. ctrl: optional per-call control.
# Returns the matching EntityName items as an arrayref; dies with
# ProjectNameError on failure.
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

  # list yields the BARE arrayref of records - each an accessible hashref -
  # so callers can index $item->{id} directly, matching py/lua/go/rb.
  # make_result wraps each entry as an Entity instance for internal use;
  # unwrap those back to their bare record hashrefs here (load/create/etc.
  # are unaffected).
  if (Voxgig::Struct::islist($records)) {
    $records = [map {
      (Scalar::Util::blessed($_) && $_->can('data_get')) ? $_->data_get : $_
    } @$records];
  }

  return $records;
}

# EJECT-END
