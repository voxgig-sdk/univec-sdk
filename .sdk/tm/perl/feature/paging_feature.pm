# Univec SDK paging feature
#
# Pagination support for list operations. On the way out (PreRequest) it
# stamps page/limit (or a cursor) into the request query; on the way back
# (PreResult) it reads the server's pagination signals - a Link rel="next"
# header, X-Page/X-Next-Page/X-Total-Count headers, or next/cursor/
# nextCursor/hasMore fields in the body - and records them on
# result.paging. A per-call ctrl paging value (page or cursor) takes
# priority. Parameter names ("pageParam", "limitParam", "cursorParam"),
# "startPage" (default 1) and page size ("limit") are configurable.

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

package UnivecPagingFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'paging';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});
  return;
}

sub PreRequest {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  return unless $self->_list($ctx);
  my $spec = $ctx->{spec};
  return unless $spec;
  $spec->{query} = {} unless defined $spec->{query};

  my $page_param = defined $self->{options}{pageParam} ? $self->{options}{pageParam} : 'page';
  my $limit_param = defined $self->{options}{limitParam} ? $self->{options}{limitParam} : 'limit';
  my $cursor_param = defined $self->{options}{cursorParam} ? $self->{options}{cursorParam} : 'cursor';

  # A per-call cursor/page from ctrl takes priority (used by auto-iteration).
  my $paging = {};
  if ($ctx->{ctrl} && Voxgig::Struct::ismap($ctx->{ctrl}{paging})) {
    $paging = $ctx->{ctrl}{paging};
  }

  # GraphQL paginates through operation VARIABLES, not the query string.
  # This hook runs after make_spec, so spec->{body} already holds the
  # { query, variables } envelope, and before make_fetch_def serialises it.
  if ('graphql' eq (UnivecHelpers::gp($ctx->{point}, 'kind') // '')) {
    $self->_graphql_pre_request($ctx, $paging);
    return;
  }

  if (defined $paging->{cursor}) {
    $spec->{query}{$cursor_param} = $paging->{cursor};
  }
  elsif (!defined $spec->{query}{$page_param}) {
    $spec->{query}{$page_param} = defined $paging->{page}
      ? $paging->{page}
      : (defined $self->{options}{startPage} ? $self->{options}{startPage} : 1);
  }

  if (defined $self->{options}{limit} && !defined $spec->{query}{$limit_param}) {
    $spec->{query}{$limit_param} = $self->{options}{limit};
  }
  return;
}

# Relay pagination: the cursor is the `after` variable (or whatever the model
# named it), and the page size is `first`.
sub _graphql_pre_request {
  my ($self, $ctx, $paging) = @_;

  my $body = $ctx->{spec}{body};
  return unless ref($body) eq 'HASH';

  my $variables = $body->{variables};
  unless (ref($variables) eq 'HASH') {
    $variables = {};
    $body->{variables} = $variables;
  }

  my $after_var = defined $self->{options}{afterVar} ? $self->{options}{afterVar} : 'after';
  my $first_var = defined $self->{options}{firstVar} ? $self->{options}{firstVar} : 'first';

  # Only bind variables the operation actually declares, or the server
  # rejects the document.
  my %declared;
  my $varlist = UnivecHelpers::gpath($ctx->{point}, 'graphql.vars');
  if (ref($varlist) eq 'ARRAY') {
    for my $v (@$varlist) {
      my $name = UnivecHelpers::gp($v, 'name');
      $declared{$name} = 1 if defined $name;
    }
  }

  if (defined $paging->{cursor} && $declared{$after_var}) {
    $variables->{$after_var} = $paging->{cursor};
  }

  if (defined $self->{options}{limit} && !defined $variables->{$first_var}
    && $declared{$first_var}) {
    $variables->{$first_var} = $self->{options}{limit};
  }
  return;
}

sub PreResult {
  my ($self, $ctx) = @_;
  return unless $self->{active};
  return unless $self->_list($ctx);
  my $result = $ctx->{result};
  return unless $result;

  my $headers = $result->{headers} || {};
  my $body = $result->{body};

  my $paging = {
    'page' => $self->_num($self->_header($headers, 'x-page')),
    'totalCount' => $self->_num($self->_header($headers, 'x-total-count')),
    'nextPage' => $self->_num($self->_header($headers, 'x-next-page')),
    'next' => undef,
    'cursor' => undef,
    'hasMore' => 0,
  };

  # Link: <...>; rel="next"
  my $link = $self->_header($headers, 'link');
  if (defined $link) {
    if ("$link" =~ /<([^>]+)>\s*;\s*rel="?next"?/i) {
      $paging->{next} = $1;
    }
  }

  # Set when the response states hasMore outright, rather than leaving it to
  # be inferred from the presence of a cursor.
  my $explicit_more = 0;

  # Relay connections carry the cursor in pageInfo, at the path the model
  # recorded for this op.
  my $page = UnivecHelpers::gpath($ctx->{point}, 'graphql.page');
  if (ref($page) eq 'HASH' && Voxgig::Struct::ismap($body)) {
    # `connpath` locates the connection object inside the response envelope
    # (data.<field>); the cursor/more paths are relative to it.
    my $conn = $body;
    my $connpath = $page->{connpath};
    if (defined $connpath && '' ne $connpath) {
      my $sub = UnivecHelpers::gpath($body, $connpath);
      $conn = $sub if defined $sub;
    }

    my $cursorpath = $page->{cursor};
    if (defined $cursorpath && '' ne $cursorpath) {
      my $cursor = UnivecHelpers::gpath($conn, $cursorpath);
      $paging->{cursor} = $cursor if defined $cursor;
    }

    my $morepath = $page->{more};
    if (defined $morepath && '' ne $morepath) {
      my $more = UnivecHelpers::gpath($conn, $morepath);
      if (UnivecHelpers::is_true($more) || UnivecHelpers::is_false($more)) {
        $paging->{hasMore} = UnivecHelpers::is_true($more) ? 1 : 0;
        $explicit_more = 1;
      }
    }
  }

  # Body-level cursors.
  if (Voxgig::Struct::ismap($body)) {
    my $bnext = UnivecHelpers::gp($body, 'next');
    $paging->{next} = defined $paging->{next} ? $paging->{next} : $bnext
      if defined $bnext;
    my $bcursor = UnivecHelpers::gp($body, 'cursor');
    $paging->{cursor} = $bcursor if defined $bcursor;
    my $bnextcursor = UnivecHelpers::gp($body, 'nextCursor');
    $paging->{cursor} = $bnextcursor if defined $bnextcursor;
    my $bhasmore = $body->{hasMore};
    if (UnivecHelpers::is_true($bhasmore) || UnivecHelpers::is_false($bhasmore)) {
      $paging->{hasMore} = UnivecHelpers::is_true($bhasmore) ? 1 : 0;
      $explicit_more = 1;
    }
  }

  # Cursor presence only INFERS another page. When the server stated the
  # answer outright - relay's `hasNextPage: false`, or a body `hasMore` -
  # that wins: a final page normally carries both an end cursor and
  # hasNextPage false, and inferring from the cursor there would send the
  # caller back for a page that does not exist, forever.
  unless ($explicit_more) {
    $paging->{hasMore} = ($paging->{hasMore}
      || defined $paging->{next} || defined $paging->{cursor}
      || defined $paging->{nextPage}) ? 1 : 0;
  }

  $result->{paging} = $paging;

  $self->{client}{_paging} = { 'last' => $paging };
  return;
}

sub _list {
  my ($self, $ctx) = @_;
  my $ops = $self->{options}{ops} || ['list'];
  my $opname = $ctx->{op} ? $ctx->{op}{name} : undef;
  return (defined $opname && grep { "$_" eq $opname } @$ops) ? 1 : 0;
}

sub _header {
  my ($self, $headers, $name) = @_;
  my $lower = lc $name;
  for my $k (keys %$headers) {
    return $headers->{$k} if lc("$k") eq $lower;
  }
  return undef;
}

sub _num {
  my ($self, $v) = @_;
  return undef unless defined $v;
  return int($v) if "$v" =~ /^-?[0-9]+$/;
  return 0 + $v if Scalar::Util::looks_like_number("$v");
  return undef;
}

1;
