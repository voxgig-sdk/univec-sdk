# Univec SDK proxy feature
#
# Outbound HTTP(S) proxy support. Wraps the active transport and attaches
# proxy routing to each request's fetch definition. The proxy target comes
# from options ("url") or, when "fromEnv" is set, the standard
# HTTPS_PROXY / HTTP_PROXY / NO_PROXY environment variables. Constructing a
# concrete agent is dependency-specific, so a factory may be supplied via
# options "agent"; when absent the request is annotated with
# fetchdef->{proxy} for the transport to honour. Hosts matching "noProxy"
# (exact or suffix) bypass the proxy.

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));
require(Cwd::abs_path("$__dir/base_feature.pm"));

package UnivecProxyFeature;

our @ISA = ('UnivecBaseFeature');

sub new {
  my ($class) = @_;
  my $self = UnivecBaseFeature::new($class);
  $self->{version} = '0.0.1';
  $self->{name} = 'proxy';
  # Inactive until init (feature_init only fires init when active).
  $self->{active} = 0;
  $self->{client} = undef;
  $self->{options} = {};
  $self->{url} = undef;
  $self->{no_proxy} = [];
  $self->{ctx} = undef;
  return $self;
}

sub init {
  my ($self, $ctx, $options) = @_;
  $self->{client} = $ctx->{client};
  $self->{options} = Voxgig::Struct::ismap($options) ? $options : {};
  $self->{active} = UnivecHelpers::is_true($self->{options}{active});

  return unless $self->{active};

  $self->{url} = $self->{options}{url};
  my $no_proxy = $self->{options}{noProxy};

  if (UnivecHelpers::is_true($self->{options}{fromEnv})) {
    $self->{url} = $self->{url}
      // $ENV{HTTPS_PROXY} // $ENV{https_proxy}
      // $ENV{HTTP_PROXY} // $ENV{http_proxy};
    $no_proxy = $no_proxy // $ENV{NO_PROXY} // $ENV{no_proxy};
  }

  my @np;
  if (defined $no_proxy && !ref $no_proxy) {
    @np = split /\s*,\s*/, "$no_proxy";
  }
  elsif (Voxgig::Struct::islist($no_proxy)) {
    @np = @$no_proxy;
  }
  $self->{no_proxy} = [grep { defined $_ && '' ne $_ } @np];

  # A proxy URL may carry credentials as userinfo, from the option or the
  # environment, and neither is under a sensitive key name.
  $self->{ctx} = $ctx;
  if (defined $self->{url} && !ref $self->{url}
    && "$self->{url}" =~ m{\A[A-Za-z][A-Za-z0-9+.-]*://([^/?#@]*)@}) {
    my $userinfo = $1;
    for my $part (split /:/, $userinfo, 2) {
      next unless defined $part && '' ne $part;
      $ctx->{utility}{clean_add}->($ctx, $part);
      my $decoded = $part;
      $decoded =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
      $ctx->{utility}{clean_add}->($ctx, $decoded);
    }
  }

  my $feature = $self;
  my $utility = $ctx->{utility};
  my $inner = $utility->{fetcher};

  $utility->{fetcher} = sub {
    my ($fctx, $fullurl, $fetchdef) = @_;
    return $inner->($fctx, $fullurl, $feature->route($fullurl, $fetchdef));
  };
  return;
}

sub route {
  my ($self, $url, $fetchdef) = @_;
  return $fetchdef if !defined $self->{url} || $self->_bypass($url);

  my $out = Voxgig::Struct::ismap($fetchdef) ? { %$fetchdef } : {};
  $out->{proxy} = $self->{url};

  my $agent = $self->{options}{agent};
  if (ref $agent eq 'CODE') {
    # Factory returns a transport-specific agent/dispatcher.
    my $made = $agent->($self->{url}, $url);
    $out->{dispatcher} = $made;
    $out->{agent} = $made;
  }

  $self->_track($url);
  return $out;
}

sub _bypass {
  my ($self, $url) = @_;
  return 0 unless @{ $self->{no_proxy} };
  my $host = $url;
  if ($url =~ m{\A[a-z]+://([^/:]+)}i) {
    $host = $1;
  }
  for my $np (@{ $self->{no_proxy} }) {
    return 1 if '*' eq $np;
    my $bare = $np;
    $bare =~ s/\A\.//;
    return 1 if $host eq $np;
    return 1 if length($host) > length($bare) + 1
      && substr($host, -(length($bare) + 1)) eq ".$bare";
  }
  return 0;
}

sub _track {
  my ($self, $url) = @_;
  my $track = $self->{client}{_proxy};
  if (!$track) {
    my $ctx = $self->{ctx};
    $track = {
      'routed' => 0,
      'url' => $ctx ? $ctx->{utility}{clean}->($ctx, $self->{url}) : $self->{url},
    };
    $self->{client}{_proxy} = $track;
  }
  $track->{routed} += 1;
  return;
}

1;
