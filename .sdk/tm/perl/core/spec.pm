# Univec SDK spec

use strict;
use warnings;

package UnivecSpec;

sub new {
  my ($class, $specmap) = @_;
  $specmap = {} unless defined $specmap && ref $specmap;
  my $g = sub {
    my ($k, $d) = @_;
    my $v = $specmap->{$k};
    return defined($v) ? $v : $d;
  };
  return bless {
    parts   => $g->('parts', []),
    headers => $g->('headers', {}),
    alias   => $g->('alias', {}),
    base    => $g->('base', ''),
    prefix  => $g->('prefix', ''),
    suffix  => $g->('suffix', ''),
    params  => $g->('params', {}),
    query   => $g->('query', {}),
    step    => $g->('step', ''),
    method  => $g->('method', 'GET'),
    body    => $specmap->{body},
    url     => $g->('url', ''),
    path    => $g->('path', ''),
  }, $class;
}

1;
