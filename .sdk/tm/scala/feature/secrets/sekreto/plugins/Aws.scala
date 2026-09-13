// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Aws.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Secrets Manager and SSM Parameter Store, as voxgig/plugin
// definitions - two kinds in one module, because they share the whole of
// the signing and calling machinery below.

package com.voxgig.sekreto.plugins

import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Base64
import scala.collection.immutable.ListMap

import com.voxgig.sekreto.*
import com.voxgig.sekreto.Providers.checkaddr

/** The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now. */
private[plugins] def awsnow(): String =
  DateTimeFormatter
    .ofPattern("yyyyMMdd'T'HHmmss'Z'")
    .withZone(ZoneOffset.UTC)
    .format(Instant.now)

/** Region and credentials, resolved for one call. */
private[plugins] case class Awsauth(
    region: String,
    keyid: String,
    secret: String,
    session: Option[String],
)

/** Region and credentials, from config first and the standard AWS_*
  * environment variables second - those are AWS's own convention, and a
  * pod or CI job that has them set should just work. Missing either is an
  * error: an AWS store with no credentials could not answer.
  */
private[plugins] def awsauth(
    region: Option[String],
    keyid: Option[String],
    secret: Option[String],
    session: Option[String],
): Awsauth =
  val useregion = first(region, getenv("AWS_REGION"), getenv("AWS_DEFAULT_REGION"))
  val usekeyid = first(keyid, getenv("AWS_ACCESS_KEY_ID"))
  val usesecret = first(secret, getenv("AWS_SECRET_ACCESS_KEY"))
  val usesession = first(session, getenv("AWS_SESSION_TOKEN"))

  if useregion.isEmpty then
    throw SekretoError("sekreto: aws: no region (set region or AWS_REGION)")

  if usekeyid.isEmpty || usesecret.isEmpty then
    throw SekretoError(
      "sekreto: aws: no credentials" +
        " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)",
    )

  Awsauth(useregion, usekeyid, usesecret, Some(usesession).filter(_.nonEmpty))

/** One signed call to an AWS JSON-1.1 API. */
private[plugins] def awscall(
    region: Option[String],
    keyid: Option[String],
    secret: Option[String],
    session: Option[String],
    addr: Option[String],
    service: String,
    target: String,
    payload: String,
): Answer =
  val auth = awsauth(region, keyid, secret, session)

  // The China partition lives under its own suffix; every other commercial
  // region is plain amazonaws.com.
  val suffix = if auth.region.startsWith("cn-") then ".amazonaws.com.cn" else ".amazonaws.com"
  val useaddr = first(addr, Some(s"https://$service.${auth.region}$suffix"))
  checkaddr(useaddr)

  val url = trimslash(useaddr) + "/"

  val extras = ListMap(
    "content-type" -> "application/x-amz-json-1.1",
    "x-amz-target" -> target,
  )

  val signed = sigv4(
    Signing(
      method = "POST",
      url = url,
      service = service,
      region = auth.region,
      keyid = auth.keyid,
      secret = auth.secret,
      datetime = awsnow(),
      headers = extras,
      body = payload,
      session = auth.session,
    ),
  )

  fetchjson("POST", url, extras ++ signed, Some(payload))

/** Does this AWS error body name one of the not-found types? Those are a
  * miss; every other failure is a store that could not answer.
  */
private[plugins] def awsmiss(body: Option[Json], types: String*): Boolean =
  body.dig("__type").asstr match
    case Some(errtype) => types.exists(errtype.contains)
    case None          => false

/** AWS Secrets Manager.
  *
  * `api.token` reads the secret named `api` (the vaultref path, so
  * `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
  * SecretString - the AWS idiom of one JSON map per secret. A SecretString
  * that is not JSON is the value itself, under the conventional field
  * `value`. Requests are SigV4-signed in-tree; see Sigv4.scala.
  */
class Awssecrets(
    region: Option[String] = None,
    keyid: Option[String] = None,
    secret: Option[String] = None,
    session: Option[String] = None,
    addr: Option[String] = None,
) extends Provider:

  override def lookup(name: String): Option[String] =
    val ref = vaultref(name)

    val res = awscall(
      region,
      keyid,
      secret,
      session,
      addr,
      "secretsmanager",
      "secretsmanager.GetSecretValue",
      Json.stringify(Json.obj("SecretId" -> Json.str(ref.path))),
    )

    if 400 == res.status && awsmiss(res.body, "ResourceNotFoundException") then None
    else if 200 != res.status then
      throw SekretoError(s"sekreto: aws secretsmanager error: ${res.status}")
    else
      res.body.dig("SecretString").asstr match
        case None =>
          // A binary secret has no fields to address; only the
          // conventional `value` field can mean "the bytes themselves".
          val bin = res.body.dig("SecretBinary").asstr

          if bin.isDefined && "value" == ref.field then
            // decode() throws IllegalArgumentException on a bad payload,
            // which is not a SekretoError and so escaped the library's own
            // error type. A store that answered incoherently is an error.
            try Some(String(Base64.getDecoder.decode(bin.get), StandardCharsets.UTF_8))
            catch
              case _: IllegalArgumentException =>
                throw SekretoError("sekreto: aws secretsmanager: undecodable secret")
          else None

        case Some(text) =>
          Json.parse(text) match
            case Some(Json.Obj(fields)) => fields.get(ref.field).flatMap(_.text)
            // A plain-string secret is the whole value; it has no named
            // fields.
            case _ => if "value" == ref.field then Some(text) else None

  // Config only, never the environment: describe() feeds the spec's
  // sources group, which must answer the same everywhere.
  override def describe(): String = s"awssecrets:${region.getOrElse("")}"

/** AWS SSM Parameter Store.
  *
  * `db.pass.main` reads the parameter `/db/pass/main` (under an optional
  * prefix path), decrypted. Parameter Store carries flat strings, so there
  * is no field indirection.
  */
class Awsparams(
    region: Option[String] = None,
    keyid: Option[String] = None,
    secret: Option[String] = None,
    session: Option[String] = None,
    addr: Option[String] = None,
    prefix: Option[String] = None,
) extends Provider:

  override def lookup(name: String): Option[String] =
    val payload = Json.obj(
      "Name" -> Json.str(awsparam(name, prefix)),
      "WithDecryption" -> Json.bool(true),
    )

    val res = awscall(
      region,
      keyid,
      secret,
      session,
      addr,
      "ssm",
      "AmazonSSM.GetParameter",
      Json.stringify(payload),
    )

    if 400 == res.status && awsmiss(res.body, "ParameterNotFound") then None
    else if 200 != res.status then throw SekretoError(s"sekreto: aws ssm error: ${res.status}")
    else res.body.dig("Parameter", "Value").text

  override def describe(): String =
    s"awsparams:${region.getOrElse("")}${prefix.getOrElse("")}"

/** The `awssecrets` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val awssecrets: Definition = providerplugin("awssecrets", spec =>
  Awssecrets(spec.region, spec.keyid, spec.secret, spec.session, spec.addr))

/** The `awsparams` provider kind, as a voxgig/plugin definition. A consumer
  * imports this and hands it to `Sekreto`; a consumer that does not gets a
  * `Sekreto` that cannot build a chain entry of that kind.
  */
val awsparams: Definition = providerplugin("awsparams", spec =>
  Awsparams(spec.region, spec.keyid, spec.secret, spec.session, spec.addr, spec.prefix))
