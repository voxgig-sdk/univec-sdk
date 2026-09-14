// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (java/plugins/com/voxgig/sekreto/plugins/Aws.java)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Secrets Manager and SSM Parameter Store, as voxgig/plugin
// definitions: two kinds, one plugin, because they share a signer.
//
// A PLUGIN, NOT PART OF THE CORE: it opens a socket and signs every
// request. SigV4 travels with it - Sigv4.java is in this folder and not
// in the core, because the core of no port imports a hash function.
// See docs/design/plugin-providers.md.

package JAVAPACKAGE.feature.secrets.sekreto.plugins;

import static JAVAPACKAGE.feature.secrets.sekreto.Addr.checkaddr;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.dig;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.fetchjson;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.first;
import static JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.trimslash;

import JAVAPACKAGE.feature.secrets.sekreto.Json;
import JAVAPACKAGE.feature.secrets.sekreto.Provider;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto;
import JAVAPACKAGE.feature.secrets.sekreto.Sekreto.SekretoError;
import JAVAPACKAGE.feature.secrets.sekreto.Support;
import JAVAPACKAGE.feature.secrets.sekreto.plugins.Httpjson.Answer;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import JAVAPACKAGE.feature.secrets.plugin.Definition;

public final class Aws {

  private Aws() {}

  /** The `awssecrets` kind: what `plugins` hands to Sekreto. */
  public static final Definition SECRETS = Support.providerplugin("awssecrets", spec ->
      new Secrets(
          Support.text(spec.get("region")), Support.text(spec.get("keyid")),
          Support.text(spec.get("secret")), Support.text(spec.get("session")),
          Support.text(spec.get("addr"))));

  /** The `awsparams` kind: what `plugins` hands to Sekreto. */
  public static final Definition PARAMS = Support.providerplugin("awsparams", spec ->
      new Params(
          Support.text(spec.get("region")), Support.text(spec.get("keyid")),
          Support.text(spec.get("secret")), Support.text(spec.get("session")),
          Support.text(spec.get("addr")), Support.text(spec.get("prefix"))));

  /** The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now. */
  static String awsnow() {
    return DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'")
        .withZone(ZoneOffset.UTC)
        .format(Instant.now());
  }

  /** Region and credentials, resolved for one call. */
  private static final class Awsauth {
    final String region;
    final String keyid;
    final String secret;
    final String session;

    Awsauth(String region, String keyid, String secret, String session) {
      this.region = region;
      this.keyid = keyid;
      this.secret = secret;
      this.session = session;
    }
  }

  /**
   * Region and credentials, from config first and the standard AWS_*
   * environment variables second - those are AWS's own convention, and a
   * pod or CI job that has them set should just work. Missing either is an
   * error: an AWS store with no credentials could not answer.
   */
  static Awsauth awsauth(String region, String keyid, String secret, String session) {
    String useregion =
        first(region, System.getenv("AWS_REGION"), System.getenv("AWS_DEFAULT_REGION"));
    String usekeyid = first(keyid, System.getenv("AWS_ACCESS_KEY_ID"));
    String usesecret = first(secret, System.getenv("AWS_SECRET_ACCESS_KEY"));
    String usesession = first(session, System.getenv("AWS_SESSION_TOKEN"));

    if (useregion.isEmpty()) {
      throw new SekretoError("sekreto: aws: no region (set region or AWS_REGION)");
    }
    if (usekeyid.isEmpty() || usesecret.isEmpty()) {
      throw new SekretoError(
          "sekreto: aws: no credentials"
              + " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)");
    }

    return new Awsauth(useregion, usekeyid, usesecret,
        usesession.isEmpty() ? null : usesession);
  }

  /** One signed call to an AWS JSON-1.1 API. */
  static Answer awscall(String region, String keyid, String secret, String session,
      String addr, String service, String target, String payload) {
    Awsauth auth = awsauth(region, keyid, secret, session);
    // The China partition lives under its own suffix; every other
    // commercial region is plain amazonaws.com.
    String suffix = auth.region.startsWith("cn-") ? ".amazonaws.com.cn" : ".amazonaws.com";
    String useaddr = first(addr, "https://" + service + "." + auth.region + suffix);
    checkaddr(useaddr);

    String url = trimslash(useaddr) + "/";

    Map<String, Object> extras = new LinkedHashMap<>();
    extras.put("content-type", "application/x-amz-json-1.1");
    extras.put("x-amz-target", target);

    Map<String, Object> input = new LinkedHashMap<>();
    input.put("method", "POST");
    input.put("url", url);
    input.put("headers", extras);
    input.put("body", payload);
    input.put("service", service);
    input.put("region", auth.region);
    input.put("keyid", auth.keyid);
    input.put("secret", auth.secret);
    if (null != auth.session) {
      input.put("session", auth.session);
    }
    input.put("datetime", awsnow());

    Map<String, Object> signed = Sigv4.sigv4(input);

    Map<String, String> send = new LinkedHashMap<>();
    for (Map.Entry<String, Object> entry : extras.entrySet()) {
      send.put(entry.getKey(), String.valueOf(entry.getValue()));
    }
    for (Map.Entry<String, Object> entry : signed.entrySet()) {
      send.put(entry.getKey(), String.valueOf(entry.getValue()));
    }

    return fetchjson("POST", url, send, payload);
  }

  /**
   * Does this AWS error body name one of the not-found types? Those are a
   * miss; every other failure is a store that could not answer.
   */
  static boolean awsmiss(Object body, String... types) {
    Object errtype = dig(body, "__type");
    if (!(errtype instanceof String)) {
      return false;
    }
    for (String type : types) {
      if (((String) errtype).contains(type)) {
        return true;
      }
    }
    return false;
  }

  /**
   * AWS Secrets Manager.
   *
   * <p>`api.token` reads the secret named `api` (the vaultref path, so
   * `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
   * SecretString - the AWS idiom of one JSON map per secret. A SecretString
   * that is not JSON is the value itself, under the conventional field
   * `value`. Requests are SigV4-signed in-tree; see Sigv4.java.
   */
  public static final class Secrets implements Provider {
    private final String region;
    private final String keyid;
    private final String secret;
    private final String session;
    private final String addr;

    public Secrets(String region, String keyid, String secret, String session, String addr) {
      this.region = region;
      this.keyid = keyid;
      this.secret = secret;
      this.session = session;
      this.addr = addr;
    }

    @Override
    @SuppressWarnings("unchecked")
    public String lookup(String name) {
      Map<String, Object> ref = Sekreto.vaultref(name);

      Map<String, Object> payload = new LinkedHashMap<>();
      payload.put("SecretId", ref.get("path"));

      Answer res = awscall(region, keyid, secret, session, addr,
          "secretsmanager", "secretsmanager.GetSecretValue", Json.stringify(payload));

      if (400 == res.status && awsmiss(res.body, "ResourceNotFoundException")) {
        return null;
      }

      if (200 != res.status) {
        throw new SekretoError("sekreto: aws secretsmanager error: " + res.status);
      }

      Object text = dig(res.body, "SecretString");

      if (!(text instanceof String)) {
        // A binary secret has no fields to address; only the conventional
        // `value` field can mean "the bytes themselves".
        Object bin = dig(res.body, "SecretBinary");
        if (bin instanceof String && "value".equals(ref.get("field"))) {
          // decode() throws IllegalArgumentException on a bad payload,
          // which is not a SekretoError and so escaped the library's own
          // error type. A store that answered incoherently is an error.
          try {
            return new String(
                Base64.getDecoder().decode((String) bin), StandardCharsets.UTF_8);
          } catch (IllegalArgumentException err) {
            throw new SekretoError("sekreto: aws secretsmanager: undecodable secret");
          }
        }
        return null;
      }

      Object parsed = Json.parse((String) text);

      if (parsed instanceof Map) {
        Object value = ((Map<String, Object>) parsed).get(ref.get("field"));
        return null == value ? null : String.valueOf(value);
      }

      // A plain-string secret is the whole value; it has no named fields.
      return "value".equals(ref.get("field")) ? (String) text : null;
    }

    // Config only, never the environment: describe() feeds the spec's
    // sources group, which must answer the same everywhere.
    @Override
    public String describe() {
      return "awssecrets:" + (null == region ? "" : region);
    }
  }

  /**
   * AWS SSM Parameter Store.
   *
   * <p>`db.pass.main` reads the parameter `/db/pass/main` (under an
   * optional prefix path), decrypted. Parameter Store carries flat strings,
   * so there is no field indirection.
   */
  public static final class Params implements Provider {
    private final String region;
    private final String keyid;
    private final String secret;
    private final String session;
    private final String addr;
    private final String prefix;

    public Params(String region, String keyid, String secret, String session,
        String addr, String prefix) {
      this.region = region;
      this.keyid = keyid;
      this.secret = secret;
      this.session = session;
      this.addr = addr;
      this.prefix = prefix;
    }

    @Override
    public String lookup(String name) {
      Map<String, Object> payload = new LinkedHashMap<>();
      payload.put("Name", Sekreto.awsparam(name, prefix));
      payload.put("WithDecryption", Boolean.TRUE);

      Answer res = awscall(region, keyid, secret, session, addr,
          "ssm", "AmazonSSM.GetParameter", Json.stringify(payload));

      if (400 == res.status && awsmiss(res.body, "ParameterNotFound")) {
        return null;
      }

      if (200 != res.status) {
        throw new SekretoError("sekreto: aws ssm error: " + res.status);
      }

      Object value = dig(res.body, "Parameter", "Value");
      return null == value ? null : String.valueOf(value);
    }

    @Override
    public String describe() {
      return "awsparams:" + (null == region ? "" : region) + (null == prefix ? "" : prefix);
    }
  }
}
