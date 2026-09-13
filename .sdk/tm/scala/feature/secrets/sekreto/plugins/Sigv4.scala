// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Sigv4.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled - AND UNDER `plugins/`.
//
// The core of no port imports a hash function. Signing is what the two AWS
// kinds need and nothing else does, so it moved here with them: a chain of
// the four built-in kinds links no MessageDigest and no Mac, which is what
// `make check-core` reads back off the compiled core.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps the ports honest. SigV4 is a stable, published algorithm built
// from HMAC-SHA256, which the JDK already has.
//
// `sigv4` is pure: the caller passes the timestamp, so the same input
// yields the same signature everywhere. That is what lets the shared spec
// carry known-answer cases that all ports must reproduce bit-for-bit, and
// lets the integration mock recompute the signature server-side.
//
// A port of typescript/plugins/sigv4.ts, which is canonical.

package com.voxgig.sekreto.plugins

import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.security.NoSuchAlgorithmException
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import scala.collection.immutable.ListMap
import scala.collection.immutable.TreeMap

import com.voxgig.sekreto.SekretoError

/** One request to sign - the same declarative shape the shared spec uses.
  * `datetime` is `YYYYMMDDTHHMMSSZ`, and it is the caller's, so that signing
  * is a pure function of its input.
  */
case class Signing(
    method: String,
    url: String,
    service: String,
    region: String,
    keyid: String,
    secret: String,
    datetime: String,
    headers: Map[String, String] = Map.empty,
    body: String = "",
    session: Option[String] = None,
)

private[plugins] def hex(bytes: Array[Byte]): String =
  val out = StringBuilder()

  for byte <- bytes do out.append("%02x".format(byte.toInt & 0xff))

  out.toString

private[plugins] def sha256hex(text: String): String =
  try hex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)))
  catch
    // Every JDK ships SHA-256; a JVM without it cannot sign anything.
    case err: NoSuchAlgorithmException =>
      throw SekretoError(s"sekreto: sigv4: no SHA-256: ${err.getMessage}")

private[plugins] def hmac(key: Array[Byte], text: String): Array[Byte] =
  try
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    mac.doFinal(text.getBytes(StandardCharsets.UTF_8))
  catch
    case err: GeneralSecurityException =>
      throw SekretoError(s"sekreto: sigv4: no HmacSHA256: ${err.getMessage}")

/** RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
  * wants everything but unreserved characters escaped, with uppercase hex.
  */
private[plugins] def uriescape(text: String): String =
  val out = StringBuilder()

  for byte <- text.getBytes(StandardCharsets.UTF_8) do
    val ch = byte.toInt & 0xff

    if ('A'.toInt <= ch && 'Z'.toInt >= ch) ||
      ('a'.toInt <= ch && 'z'.toInt >= ch) ||
      ('0'.toInt <= ch && '9'.toInt >= ch) ||
      '-'.toInt == ch || '_'.toInt == ch || '.'.toInt == ch || '~'.toInt == ch
    then out.append(ch.toChar)
    else out.append('%').append("%02X".format(ch))

  out.toString

/** Two hex digits as a byte, or None. `toIntOption` reads decimal only. */
private def hexbyte(text: String): Option[Int] =
  try Some(Integer.parseInt(text, 16))
  catch case _: NumberFormatException => None

/** Percent-decode, and nothing else: `+` stays `+`, as on the wire. */
private[plugins] def uridecode(text: String): String =
  val out = ByteArrayOutputStream()
  var index = 0

  while index < text.length do
    val head = text(index)
    var taken = false

    if '%' == head && index + 2 < text.length then
      hexbyte(text.substring(index + 1, index + 3)) match
        case Some(code) =>
          out.write(code)
          index += 3
          taken = true
        // A stray % is kept as-is, the way a browser would.
        case None => ()

    if !taken then
      out.write(head.toString.getBytes(StandardCharsets.UTF_8))
      index += 1

  String(out.toByteArray, StandardCharsets.UTF_8)

/** The canonical query string: each pair RFC 3986-escaped, sorted by escaped
  * key then escaped value.
  */
private[plugins] def canonicalquery(query: String): String =
  if query.isEmpty then ""
  else
    query
      .split("&", -1)
      .map: pair =>
        val eq = pair.indexOf('=')
        val key = if -1 == eq then pair else pair.substring(0, eq)
        val value = if -1 == eq then "" else pair.substring(eq + 1)
        (uriescape(uridecode(key)), uriescape(uridecode(value)))
      .sortBy(pair => (pair._1, pair._2))
      .map((key, value) => s"$key=$value")
      .mkString("&")

/** Sign one request. Returns the headers to attach: authorization,
  * x-amz-date, and x-amz-security-token when a session token was given, in
  * that order - the spec compares the result as a JSON object, and callers
  * print it field by field.
  */
def sigv4(input: Signing): ListMap[String, String] =
  val url = URI.create(input.url)

  val date = input.datetime.substring(0, 8)
  val session = input.session.filter(_.nonEmpty)

  // Every header that will be signed: the caller's extras, plus host and
  // x-amz-date (and the session token when present), lower-cased and trimmed
  // the way the canonical form requires. A TreeMap keeps them sorted by
  // name, which is the canonical order.
  //
  // Canonical header values are trimmed AND internally collapsed - AWS folds
  // sequential whitespace to one space before signing, so a header like
  // "a  b" must sign as "a b" or the service refuses it.
  var headers = TreeMap.empty[String, String]

  for (key, value) <- input.headers do
    headers = headers.updated(key.toLowerCase(Locale.ROOT), value.trim.replaceAll("\\s+", " "))

  headers = headers.updated("host", url.getHost + (if -1 == url.getPort then "" else s":${url.getPort}"))
  headers = headers.updated("x-amz-date", input.datetime)
  session.foreach(value => headers = headers.updated("x-amz-security-token", value))

  val canonicalheaders = headers.toList.map((key, value) => s"$key:$value\n").mkString
  val signedheaders = headers.keys.mkString(";")

  val rawpath = url.getRawPath
  val path = if null == rawpath || rawpath.isEmpty then "/" else rawpath
  val query = Option(url.getRawQuery).getOrElse("")

  val canonicalrequest = List(
    input.method.toUpperCase(Locale.ROOT),
    path,
    canonicalquery(query),
    canonicalheaders,
    signedheaders,
    sha256hex(input.body),
  ).mkString("\n")

  val scope = s"$date/${input.region}/${input.service}/aws4_request"

  val stringtosign = List(
    "AWS4-HMAC-SHA256",
    input.datetime,
    scope,
    sha256hex(canonicalrequest),
  ).mkString("\n")

  val kdate = hmac(("AWS4" + input.secret).getBytes(StandardCharsets.UTF_8), date)
  val kregion = hmac(kdate, input.region)
  val kservice = hmac(kregion, input.service)
  val ksigning = hmac(kservice, "aws4_request")
  val signature = hex(hmac(ksigning, stringtosign))

  var out = ListMap.empty[String, String]

  out = out.updated(
    "authorization",
    s"AWS4-HMAC-SHA256 Credential=${input.keyid}/$scope" +
      s", SignedHeaders=$signedheaders" +
      s", Signature=$signature",
  )
  out = out.updated("x-amz-date", input.datetime)

  session.foreach(value => out = out.updated("x-amz-security-token", value))

  out
