// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (dart/plugins/aws.dart)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260908-1556-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The two AWS stores, as voxgig/plugin definitions - and `sigv4` with them.
//
// PLUGINS, not built-ins, and this is the file the design names: request
// signing is HMAC-SHA256, and the core of no port imports a hash function.
// `sigv4.dart` and `crypto.dart` sit beside this file rather than under
// `src/`, so a chain of the four built-in kinds compiles neither.
// A `Sekreto` can build `awssecrets` or `awsparams` only if the calling
// project imported this file and passed them in the `plugins` option
// (docs/design/plugin-providers.md).
//
// A port of typescript/plugins/aws.ts, which is canonical.

import 'dart:async';

import '../src/addr.dart';
import '../src/json.dart';
import '../src/provider.dart';
import '../src/providers.dart';
import '../src/sekreto.dart';
import '../src/support.dart';

import 'httpjson.dart';
import 'sigv4.dart';

/// Now, as the `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants.
String awsnow() {
  final now = DateTime.now().toUtc();
  String two(int value) => value.toString().padLeft(2, '0');

  return '${now.year.toString().padLeft(4, '0')}${two(now.month)}'
      '${two(now.day)}T${two(now.hour)}${two(now.minute)}'
      '${two(now.second)}Z';
}

/// One signed AWS call, prepared without touching the network.
class _Awscall {
  final String url;
  final Map<String, String> headers;
  final String payload;
  const _Awscall(this.url, this.headers, this.payload);
}

/// Region and credentials, from config first and the standard AWS_*
/// environment variables second - those are AWS's own convention, and a pod
/// or CI job that has them set should just work. Missing either is an error:
/// an AWS store with no credentials could not answer.
///
/// Resolved, checked and signed synchronously, so a chain with no
/// credentials fails where it is configured rather than somewhere inside a
/// network call.
_Awscall awsprep({
  String? region,
  String? keyid,
  String? secret,
  String? session,
  String? addr,
  required String service,
  required String target,
  required String payload,
}) {
  final useregion =
      first([region, getenv('AWS_REGION'), getenv('AWS_DEFAULT_REGION')]);
  final usekeyid = first([keyid, getenv('AWS_ACCESS_KEY_ID')]);
  final usesecret = first([secret, getenv('AWS_SECRET_ACCESS_KEY')]);
  final usesession = first([session, getenv('AWS_SESSION_TOKEN')]);

  if (useregion.isEmpty) {
    throw SekretoError('sekreto: aws: no region (set region or AWS_REGION)');
  }

  if (usekeyid.isEmpty || usesecret.isEmpty) {
    throw SekretoError(
      'sekreto: aws: no credentials'
      ' (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)',
    );
  }

  // The China partition lives under its own suffix; every other commercial
  // region is plain amazonaws.com.
  final suffix =
      useregion.startsWith('cn-') ? '.amazonaws.com.cn' : '.amazonaws.com';
  final useaddr = first([addr, 'https://$service.$useregion$suffix']);
  checkaddr(useaddr);

  final url = '${trimslash(useaddr)}/';

  final extras = <String, String>{
    'content-type': 'application/x-amz-json-1.1',
    'x-amz-target': target,
  };

  final signed = sigv4(Signing(
    method: 'POST',
    url: url,
    service: service,
    region: useregion,
    keyid: usekeyid,
    secret: usesecret,
    datetime: awsnow(),
    headers: extras,
    body: payload,
    session: usesession.isEmpty ? null : usesession,
  ));

  final headers = <String, String>{...extras, ...signed};

  return _Awscall(url, headers, payload);
}

/// Does this AWS error body name one of the not-found types? Those are a
/// miss; every other failure is a store that could not answer.
///
/// A containment test, because AWS sends the type fully qualified:
/// `com.amazonaws.service#ResourceNotFoundException`.
bool awsmiss(Json? body, String type) {
  final errtype = body.dig('__type').asstr;
  return null != errtype && errtype.contains(type);
}

/// AWS Secrets Manager.
///
/// `api.token` reads the secret named `api` (the vaultref path, so
/// `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
/// SecretString - the AWS idiom of one JSON map per secret. A SecretString
/// that is not JSON is the value itself, under the conventional field
/// `value`. Requests are SigV4-signed in-tree; see sigv4.dart.
class Awssecrets extends Provider {
  final String? region;
  final String? keyid;
  final String? secret;
  final String? session;
  final String? addr;

  Awssecrets({this.region, this.keyid, this.secret, this.session, this.addr});

  @override
  FutureOr<String?> lookup(String name) {
    final ref = vaultref(name);

    final call = awsprep(
      region: region,
      keyid: keyid,
      secret: secret,
      session: session,
      addr: addr,
      service: 'secretsmanager',
      target: 'secretsmanager.GetSecretValue',
      payload: jsonstringify(JsonObj({'SecretId': JsonStr(ref.path)})),
    );

    return _read(call, ref);
  }

  Future<String?> _read(_Awscall call, VaultRef ref) async {
    final res = await fetchjson('POST', call.url,
        headers: call.headers, body: call.payload);

    if (400 == res.status && awsmiss(res.body, 'ResourceNotFoundException')) {
      return null;
    }
    if (200 != res.status) {
      throw SekretoError('sekreto: aws secretsmanager error: ${res.status}');
    }

    final text = res.body.dig('SecretString').asstr;

    if (null == text) {
      // A binary secret has no fields to address; only the conventional
      // `value` field can mean "the bytes themselves".
      final binary = res.body.dig('SecretBinary').asstr;

      if (null == binary || 'value' != ref.field) {
        return null;
      }

      final decoded = unbase64(binary);
      if (null == decoded) {
        throw SekretoError('sekreto: aws secretsmanager: undecodable secret');
      }
      return decoded;
    }

    final parsed = jsonparse(text);
    final fields = parsed.asobj;

    if (null != fields) {
      return fields[ref.field].text;
    }

    // A plain-string secret is the whole value; it has no named fields.
    return 'value' == ref.field ? text : null;
  }

  // Config only, never the environment: describe() feeds the spec's sources
  // group, which must answer the same everywhere.
  @override
  String describe() => 'awssecrets:${region ?? ''}';
}

/// AWS SSM Parameter Store.
///
/// `db.pass.main` reads the parameter `/db/pass/main` (under an optional
/// prefix path), decrypted. Parameter Store carries flat strings, so there
/// is no field indirection.
class Awsparams extends Provider {
  final String? region;
  final String? keyid;
  final String? secret;
  final String? session;
  final String? addr;
  final String? prefix;

  Awsparams({
    this.region,
    this.keyid,
    this.secret,
    this.session,
    this.addr,
    this.prefix,
  });

  @override
  FutureOr<String?> lookup(String name) {
    final call = awsprep(
      region: region,
      keyid: keyid,
      secret: secret,
      session: session,
      addr: addr,
      service: 'ssm',
      target: 'AmazonSSM.GetParameter',
      payload: jsonstringify(JsonObj({
        'Name': JsonStr(awsparam(name, prefix)),
        'WithDecryption': const JsonBool(true),
      })),
    );

    return _read(call);
  }

  Future<String?> _read(_Awscall call) async {
    final res = await fetchjson('POST', call.url,
        headers: call.headers, body: call.payload);

    if (400 == res.status && awsmiss(res.body, 'ParameterNotFound')) {
      return null;
    }
    if (200 != res.status) {
      throw SekretoError('sekreto: aws ssm error: ${res.status}');
    }

    return res.body.dig('Parameter', 'Value').text;
  }

  @override
  String describe() => 'awsparams:${region ?? ''}${prefix ?? ''}';
}

/// The `awssecrets` provider kind - AWS Secrets Manager.
final Definition awssecrets = providerplugin(
  'awssecrets',
  (spec) => Awssecrets(
    region: spec.region,
    keyid: spec.keyid,
    secret: spec.secret,
    session: spec.session,
    addr: spec.addr,
  ),
);

/// The `awsparams` provider kind - AWS SSM Parameter Store.
final Definition awsparams = providerplugin(
  'awsparams',
  (spec) => Awsparams(
    region: spec.region,
    keyid: spec.keyid,
    secret: spec.secret,
    session: spec.session,
    addr: spec.addr,
    prefix: spec.prefix,
  ),
);
