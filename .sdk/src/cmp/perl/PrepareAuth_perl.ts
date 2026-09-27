
import {
  Content,
  File,
  Folder,
  cmp,
  isAuthSuppressed,
  isHttpBasicAuth,
  resolveAuthIn,
  resolveAuthName,
} from '@voxgig/sdkgen'


import {
  perlStringLiteral,
} from './utility_perl'


const PrepareAuth = cmp(async function PrepareAuth(props: any) {
  const { model } = props.ctx$

  const active = !isAuthSuppressed(model)
  const where = resolveAuthIn(model)
  const name = resolveAuthName(model)
  const basic = isHttpBasicAuth(model)

  Folder({ name: 'utility' }, () => {
    File({ name: 'prepare_auth.pm' }, () => {
      Content(render({ Name: model.const.Name, active, where, name, basic }))
    })
  })
})


type AuthSpec = {
  Name: string,
  active: boolean,
  where: string,
  name: string,
  basic: boolean,
}


function credName(spec: AuthSpec): string {
  return 'header' === spec.where ? spec.name.toLowerCase() : spec.name
}


function render(spec: AuthSpec): string {
  return spec.active ? renderActive(spec) : renderInactive(spec)
}


function renderInactive(spec: AuthSpec): string {
  return `# ${spec.Name} SDK utility: prepare_auth

use strict;
use warnings;

use File::Basename ();
use Cwd ();

my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package ${spec.Name}Utilities;

our %REGISTRY;

# This API declares no authentication, so there is no credential to
# place. The entry stays in the registry because make_spec calls it
# unconditionally, and still guards the spec so the auth_no_spec contract
# holds for every SDK.
$REGISTRY{prepare_auth} = sub {
  my ($ctx) = @_;
  my $spec = $ctx->{spec};
  return (undef, $ctx->make_error('auth_no_spec',
    'Expected context spec property to be defined.')) unless $spec;

  return ($spec, undef);
};

1;
`
}


function renderActive(spec: AuthSpec): string {
  const cred = perlStringLiteral(credName(spec))

  // HTTP Basic is header-only by definition: the scheme is
  // `Authorization: Basic base64(user:pass)`. It cannot be expressed as a
  // query parameter or a cookie, so the branch — and the core module it
  // needs — are emitted only where they can mean something.
  const wantBasic = spec.basic && 'header' === spec.where

  const use64 = wantBasic ? `use MIME::Base64 ();\n` : ''
  const secretConst = wantBasic ?
    `my $OPTION_SECRET = 'secret';\n` : ''

  return `# ${spec.Name} SDK utility: prepare_auth

use strict;
use warnings;

use File::Basename ();
use Cwd ();
${use64}
my $__dir;
BEGIN { $__dir = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
require(Cwd::abs_path("$__dir/../lib/Voxgig/Struct.pm"));
require(Cwd::abs_path("$__dir/../core/helpers.pm"));

package ${spec.Name}Utilities;

our %REGISTRY;

${placementNote(spec)}my $CRED_NAME = ${cred};
my $OPTION_APIKEY = 'apikey';
${secretConst}my $NOT_FOUND = '__NOTFOUND__';

$REGISTRY{prepare_auth} = sub {
  my ($ctx) = @_;
  my $spec = $ctx->{spec};
  return (undef, $ctx->make_error('auth_no_spec',
    'Expected context spec property to be defined.')) unless $spec;

${bag(spec)}  my $options = $ctx->{client}->options_map;

  # Public APIs that need no auth omit the options.auth block entirely.
${noCredNote(spec)}  if (!defined ${spec.Name}Helpers::gp($options, 'auth')) {
${clear(spec, '    ')}    return ($spec, undef);
  }

  my $apikey = Voxgig::Struct::getprop($options, $OPTION_APIKEY, $NOT_FOUND);
${basicBlock(spec, wantBasic)}${credBlock(spec)}
  return ($spec, undef);
};

1;
`
}


// The missing-credential test, verbatim from the template so the four
// "no credential" shapes it distinguishes (undef, the NONE sentinel, a
// JSON null, the not-found marker or an empty string) keep behaving
// identically.
const MISSING = `  if (!defined $apikey || Voxgig::Struct::is_none($apikey)
    || Voxgig::Struct::is_jnull($apikey)
    || (!ref $apikey && ($apikey eq $NOT_FOUND || $apikey eq ''))) {`


function credBlock(spec: AuthSpec): string {
  if ('cookie' === spec.where) {
    return `
${MISSING}
    return ($spec, undef);
  }

${place(spec).replace(/^ {4}/gm, '  ')}`
  }

  return `
${MISSING}
${clear(spec, '    ')}  }
  else {
${place(spec)}  }
`
}


function noCredNote(spec: AuthSpec): string {
  if ('cookie' !== spec.where) {
    return ''
  }

  return `  # Nothing of OURS to remove either way: this SDK appends its pair to
  # whatever cookie header the caller set and never stores one, and
  # prepare_headers rebuilds that header from options on every request.
`
}


function placementNote(spec: AuthSpec): string {
  if ('query' === spec.where) {
    return `# This API carries its credential as a QUERY PARAMETER (the spec's\n` +
      `# securityScheme says in: query), not as a header.\n`
  }
  if ('cookie' === spec.where) {
    return `# This API carries its credential as a COOKIE (the spec's\n` +
      `# securityScheme says in: cookie), not as a header.\n`
  }
  return ''
}


// The bag the credential lands in. Cookies ride the header bag, because a
// cookie IS a header.
function bag(spec: AuthSpec): string {
  if ('query' === spec.where) {
    return `  my $query = $spec->{query};
  unless (Voxgig::Struct::ismap($query)) {
    $query = {};
    $spec->{query} = $query;
  }

`
  }

  return `  my $headers = $spec->{headers};
`
}


function clear(spec: AuthSpec, ind: string): string {
  if ('query' === spec.where) {
    return `${ind}delete $query->{$CRED_NAME};\n`
  }

  if ('cookie' === spec.where) {
    return ''
  }

  return `${ind}delete $headers->{$CRED_NAME};\n`
}


function place(spec: AuthSpec): string {
  if ('query' === spec.where) {
    return `    # NO PREFIX IN A QUERY STRING: \`?token=Bearer%20abc\` is not a thing
    # any API reads. The prefix is a header convention, and is dropped
    # here deliberately rather than silently concatenated. make_url
    # url-encodes both the name and the value.
    $query->{$CRED_NAME} = (!ref $apikey) ? "$apikey" : '';
`
  }

  if ('cookie' === spec.where) {
    return `    my $apikey_val = (!ref $apikey) ? "$apikey" : '';
    my $pair = "$CRED_NAME=$apikey_val";
    # APPEND, never clobber: the caller's own cookie header may already
    # carry a session or consent pair that the API needs alongside this
    # credential.
    my $cookie = $headers->{'cookie'};
    $cookie = '' unless defined $cookie && !ref $cookie;
    $headers->{'cookie'} = ('' eq $cookie) ? $pair : "$cookie; $pair";
`
  }

  return `    my $auth_prefix = ${spec.Name}Helpers::gpath($options, 'auth.prefix');
    $auth_prefix = '' unless defined $auth_prefix && !ref $auth_prefix;
    my $apikey_val = (!ref $apikey) ? "$apikey" : '';
    # Empty prefix (raw apiKey credential) must not add a leading space.
    $headers->{$CRED_NAME} =
      ('' eq $auth_prefix) ? $apikey_val : "$auth_prefix $apikey_val";
`
}


function basicBlock(spec: AuthSpec, wantBasic: boolean): string {
  if (!wantBasic) {
    return ''
  }

  return `
  # True HTTP Basic Auth needs TWO credentials, base64-joined - a single
  # token in the header (the branch below) can never authenticate against
  # an API that actually checks \`Authorization: Basic base64(user:pass)\`.
  if (${spec.Name}Helpers::is_true(${spec.Name}Helpers::gpath($options, 'auth.basic'))) {
    my $secret = Voxgig::Struct::getprop($options, $OPTION_SECRET, $NOT_FOUND);

    my $no_apikey = !defined $apikey || Voxgig::Struct::is_none($apikey)
      || Voxgig::Struct::is_jnull($apikey)
      || (!ref $apikey && ($apikey eq $NOT_FOUND || $apikey eq ''));
    my $no_secret = !defined $secret || Voxgig::Struct::is_none($secret)
      || Voxgig::Struct::is_jnull($secret)
      || (!ref $secret && ($secret eq $NOT_FOUND || $secret eq ''));

    if ($no_apikey || $no_secret) {
      delete $headers->{$CRED_NAME};
    }
    else {
      my $auth_prefix = ${spec.Name}Helpers::gpath($options, 'auth.prefix');
      $auth_prefix = '' unless defined $auth_prefix && !ref $auth_prefix;
      # '' as the eol: encode_base64 wraps at 76 columns by default, and a
      # newline inside a header value is not a header value.
      my $b64 = MIME::Base64::encode_base64("$apikey:$secret", '');
      $headers->{$CRED_NAME} =
        ('' eq $auth_prefix) ? $b64 : "$auth_prefix $b64";
    }

    return ($spec, undef);
  }
`
}


export {
  PrepareAuth
}
