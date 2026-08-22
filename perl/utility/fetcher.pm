# Univec SDK utility: fetcher

use strict;
use warnings;

use File::Basename ();
use Cwd ();
use HTTP::Tiny ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecUtilities;

our %REGISTRY;

our $DefaultHttpFetch = sub {
  my ($fullurl, $fetchdef) = @_;
  $fetchdef = {} unless defined $fetchdef;

  my $method = uc(defined $fetchdef->{method} ? "$fetchdef->{method}" : 'GET');
  my $body = $fetchdef->{body};
  my $headers = Voxgig::Struct::ismap($fetchdef->{headers}) ? $fetchdef->{headers} : {};

  my %hdrs;
  my $has_ua = 0;
  for my $k (keys %$headers) {
    my $v = $headers->{$k};
    next unless defined $v && !ref $v;
    $has_ua = 1 if lc("$k") eq 'user-agent';
    $hdrs{$k} = "$v";
  }
  # Default User-Agent - some CDNs block library defaults. Use a
  # Mozilla-shaped UA unless the caller already set one.
  $hdrs{'User-Agent'} = 'Mozilla/5.0 (compatible; UnivecSDK/1.0)' unless $has_ua;

  my $opts = { headers => \%hdrs };
  $opts->{content} = "$body" if defined $body && !ref $body;

  # fetchdef.redirect 'manual' (the ts fetch vocabulary): return a 3xx
  # as-is instead of following it. HTTP::Tiny follows redirects by
  # default; the station feature's hosts policy sets this so a Location
  # off the allowlist can never pull an automatic credentialed follow-up.
  my %new_args;
  $new_args{max_redirect} = 0
    if defined $fetchdef->{redirect} && !ref $fetchdef->{redirect}
      && 'manual' eq $fetchdef->{redirect};

  my $res = eval { HTTP::Tiny->new(%new_args)->request($method, $fullurl, $opts) };
  if (!$res) {
    my $e = defined $@ ? "$@" : 'request failed';
    $e =~ s/\s+\z//;
    return ({
      'status' => 0, 'statusText' => $e, 'headers' => {},
      'json' => sub { undef }, 'body' => undef,
    }, undef);
  }

  # Network-level failures (DNS, TCP, TLS, timeouts) - HTTP::Tiny signals
  # these with a synthesized 599 + the error text as content. Return a
  # status-0 response so callers can branch on result.ok like any other
  # failed request, instead of seeing an unhandled exception.
  if (599 == ($res->{status} || 0) && !$res->{success}) {
    my $reason = defined $res->{content} ? "$res->{content}" : 'network error';
    $reason =~ s/\s+\z//;
    return ({
      'status' => 0, 'statusText' => $reason, 'headers' => {},
      'json' => sub { undef }, 'body' => undef,
    }, undef);
  }

  my $resp_headers = {};
  my $rh = $res->{headers} || {};
  for my $k (keys %$rh) {
    my $v = $rh->{$k};
    $v = join(', ', @$v) if ref $v eq 'ARRAY';
    $resp_headers->{lc "$k"} = $v;
  }

  my $json_body;
  if (defined $res->{content} && length $res->{content}) {
    $json_body = eval { Voxgig::Struct::parse_json($res->{content}) };
  }
  my $captured = $json_body;

  return ({
    'status' => int($res->{status} || 0),
    'statusText' => (defined $res->{reason} ? "$res->{reason}" : ''),
    'headers' => $resp_headers,
    'json' => sub { $captured },
    'body' => $res->{content},
  }, undef);
};

$REGISTRY{fetcher} = sub {
  my ($ctx, $fullurl, $fetchdef) = @_;

  my $mode = $ctx->{client}{mode};
  $mode = '' unless defined $mode;
  if ('live' ne $mode) {
    return (undef, $ctx->make_error('fetch_mode_block',
      "Request blocked by mode: \"$mode\" (URL was: \"$fullurl\")"));
  }

  my $options = $ctx->{client}->options_map;
  if (UnivecHelpers::is_true(UnivecHelpers::gpath($options, 'feature.test.active'))) {
    return (undef, $ctx->make_error('fetch_test_block',
      "Request blocked as test feature is active (URL was: \"$fullurl\")"));
  }

  my $sys_fetch = UnivecHelpers::gpath($options, 'system.fetch');

  return $DefaultHttpFetch->($fullurl, $fetchdef) if !defined $sys_fetch;
  return $sys_fetch->($fullurl, $fetchdef) if ref $sys_fetch eq 'CODE';

  return (undef, $ctx->make_error('fetch_invalid', 'system.fetch is not a valid function'));
};

1;
