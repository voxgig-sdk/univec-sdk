# Univec SDK utility: prepare_auth

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package UnivecUtilities;

our %REGISTRY;

my $HEADER_AUTH = 'authorization';
my $OPTION_APIKEY = 'apikey';
my $NOT_FOUND = '__NOTFOUND__';

$REGISTRY{prepare_auth} = sub {
  my ($ctx) = @_;
  my $spec = $ctx->{spec};
  return (undef, $ctx->make_error('auth_no_spec',
    'Expected context spec property to be defined.')) unless $spec;

  my $headers = $spec->{headers};
  my $options = $ctx->{client}->options_map;

  # Public APIs that need no auth omit the options.auth block entirely.
  if (!defined UnivecHelpers::gp($options, 'auth')) {
    delete $headers->{$HEADER_AUTH};
    return ($spec, undef);
  }

  my $apikey = Voxgig::Struct::getprop($options, $OPTION_APIKEY, $NOT_FOUND);

  if (!defined $apikey || Voxgig::Struct::is_none($apikey)
    || Voxgig::Struct::is_jnull($apikey)
    || (!ref $apikey && ($apikey eq $NOT_FOUND || $apikey eq ''))) {
    delete $headers->{$HEADER_AUTH};
  }
  else {
    my $auth_prefix = UnivecHelpers::gpath($options, 'auth.prefix');
    $auth_prefix = '' unless defined $auth_prefix && !ref $auth_prefix;
    my $apikey_val = (!ref $apikey) ? "$apikey" : '';
    # Empty prefix (raw apiKey credential) must not add a leading space.
    $headers->{$HEADER_AUTH} =
      ('' eq $auth_prefix) ? $apikey_val : "$auth_prefix $apikey_val";
  }

  return ($spec, undef);
};

1;
