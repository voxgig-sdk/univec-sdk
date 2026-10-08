
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
${'cookie' === spec.where ? 'require(Cwd::abs_path("$__dir/prepare_headers.pm"));\n' : ''}
package ${spec.Name}Utilities;

our %REGISTRY;

${placementNote(spec)}my $CRED_NAME = ${cred};
${'cookie' === spec.where ? `my $COOKIE_HEADER = 'cookie';
` : ''}my $OPTION_APIKEY = 'apikey';
${secretConst}my $NOT_FOUND = '__NOTFOUND__';

# The client's auth.name option, when set, replaces the name the API declares.
my $auth_name = sub {
  my ($options) = @_;
  my $name = ${spec.Name}Helpers::gpath($options, 'auth.name');
  return (defined $name && !ref $name && '' ne $name) ? ${'header' === spec.where ? 'lc($name)' : '$name'} : $CRED_NAME;
};
${cookieHelper(spec)}
$REGISTRY{prepare_auth} = sub {
  my ($ctx) = @_;
  my $spec = $ctx->{spec};
  return (undef, $ctx->make_error('auth_no_spec',
    'Expected context spec property to be defined.')) unless $spec;

${bag(spec)}  my $options = $ctx->{client}->options_map;

  # Public APIs that need no auth omit the options.auth block entirely.
  if (!defined ${spec.Name}Helpers::gp($options, 'auth')) {
${clear(spec, '$CRED_NAME', '    ')}    return ($spec, undef);
  }

  my $name = $auth_name->($options);

  # A credential left under the declared name would travel beside the renamed one.
  if ($name ne $CRED_NAME) {
${clear(spec, '$CRED_NAME', '    ')}  }

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
  return `
${MISSING}
${clear(spec, '$name', '    ')}  }
  else {
${place(spec)}  }
`
}


// The cookie header is shared with whatever cookies the caller set, so the
// credential's pair is spliced in and out rather than appended.
function cookieHelper(spec: AuthSpec): string {
  if ('cookie' !== spec.where) {
    return ''
  }

  return `
# Rewrite the cookie header with the named pair removed, then set to VALUE
# when VALUE is defined; every other cookie is kept in order.
my $set_cookie = sub {
  my ($headers, $name, $value) = @_;
  my $existing = $headers->{$COOKIE_HEADER};
  my @kept = defined $existing && !ref $existing ? @{ cookie_keep($existing, { $name => 1 }) } : ();
  push @kept, "$name=$value" if defined $value;
  if (@kept) {
    $headers->{$COOKIE_HEADER} = join('; ', @kept);
  }
  else {
    delete $headers->{$COOKIE_HEADER};
  }
};
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


function clear(spec: AuthSpec, name: string, ind: string): string {
  if ('query' === spec.where) {
    return `${ind}delete $query->{${name}};\n`
  }

  if ('cookie' === spec.where) {
    return `${ind}$set_cookie->($headers, ${name}, undef);\n`
  }

  return `${ind}delete $headers->{${name}};\n`
}


function place(spec: AuthSpec): string {
  if ('query' === spec.where) {
    return `    # NO PREFIX IN A QUERY STRING: \`?token=Bearer%20abc\` is not a thing
    # any API reads. The prefix is a header convention, and is dropped
    # here deliberately rather than silently concatenated. make_url
    # url-encodes both the name and the value.
    $query->{$name} = (!ref $apikey) ? "$apikey" : '';
`
  }

  if ('cookie' === spec.where) {
    return `    my $apikey_val = (!ref $apikey) ? "$apikey" : '';
    # Spliced in, replacing an earlier pair of the same name, beside any
    # session or consent pair the caller's own cookie header carries.
    $set_cookie->($headers, $name, $apikey_val);
`
  }

  return `    my $auth_prefix = ${spec.Name}Helpers::gpath($options, 'auth.prefix');
    $auth_prefix = '' unless defined $auth_prefix && !ref $auth_prefix;
    my $apikey_val = (!ref $apikey) ? "$apikey" : '';
    # Empty prefix (raw apiKey credential) must not add a leading space.
    $headers->{$name} =
      ('' eq $auth_prefix) ? $apikey_val : "$auth_prefix $apikey_val";
`
}


function basicBlock(spec: AuthSpec, wantBasic: boolean): string {
  if (!wantBasic) {
    return ''
  }

  return `
  # True HTTP Basic Auth joins the two credentials, base64-encoded - a single
  # token in the header (the branch below) can never authenticate against
  # an API that actually checks \`Authorization: Basic base64(user:pass)\`.
  # The password may be empty (RFC 7617): Lob, for one, documents the key as
  # the user with a blank password (\`curl -u key:\`).
  if (${spec.Name}Helpers::is_true(${spec.Name}Helpers::gpath($options, 'auth.basic'))) {
    my $secret = Voxgig::Struct::getprop($options, $OPTION_SECRET, $NOT_FOUND);

    my $no_apikey = !defined $apikey || Voxgig::Struct::is_none($apikey)
      || Voxgig::Struct::is_jnull($apikey)
      || (!ref $apikey && ($apikey eq $NOT_FOUND || $apikey eq ''));
    my $no_secret = !defined $secret || Voxgig::Struct::is_none($secret)
      || Voxgig::Struct::is_jnull($secret)
      || (!ref $secret && ($secret eq $NOT_FOUND || $secret eq ''));

    if ($no_apikey) {
      delete $headers->{$name};
    }
    else {
      my $auth_prefix = ${spec.Name}Helpers::gpath($options, 'auth.prefix');
      $auth_prefix = '' unless defined $auth_prefix && !ref $auth_prefix;
      # '' as the eol: encode_base64 wraps at 76 columns by default, and a
      # newline inside a header value is not a header value.
      my $pass = $no_secret ? '' : $secret;
      my $b64 = MIME::Base64::encode_base64("$apikey:$pass", '');
      # The joined, encoded pair is a wire form neither credential's own
      # registration covers.
      $ctx->{utility}{clean_add}->($ctx, $b64);
      $headers->{$name} =
        ('' eq $auth_prefix) ? $b64 : "$auth_prefix $b64";
    }

    return ($spec, undef);
  }
`
}


export {
  PrepareAuth
}
