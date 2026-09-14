// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Sigv4.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// AWS Signature Version 4, hand-rolled.
//
// The AWS providers need exactly one thing from the AWS SDK - request
// signing - and taking the SDK for it would break the no-dependency rule
// that keeps ten ports honest. SigV4 is a stable, published algorithm built
// from HMAC-SHA256, which the JDK already has.
//
// `sigv4` is pure: the caller passes the timestamp, so the same input
// yields the same signature everywhere. That is what lets the shared spec
// carry known-answer cases that all ports must reproduce bit-for-bit, and
// lets the integration mock recompute the signature server-side.
//
// SIGV4 IS A PLUGIN, and travels with the aws providers that are its
// only callers: the core of no port imports a hash function.
//
// A port of typescript/plugins/sigv4.ts, which is canonical.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError

import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.security.NoSuchAlgorithmException
import java.util.TreeMap
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * One request to sign - the same declarative shape the shared spec uses.
 * `datetime` is `YYYYMMDDTHHMMSSZ`, and it is the caller's, so that signing
 * is a pure function of its input.
 */
data class Signing(
    val method: String,
    val url: String,
    val service: String,
    val region: String,
    val keyid: String,
    val secret: String,
    val datetime: String,
    val headers: Map<String, String> = emptyMap(),
    val body: String = "",
    val session: String? = null,
)

internal fun hex(bytes: ByteArray): String {
    val out = StringBuilder()

    for (byte in bytes) {
        out.append("%02x".format(byte.toInt() and 0xff))
    }

    return out.toString()
}

internal fun sha256hex(text: String): String =
    try {
        hex(MessageDigest.getInstance("SHA-256").digest(text.toByteArray(StandardCharsets.UTF_8)))
    } catch (err: NoSuchAlgorithmException) {
        // Every JDK ships SHA-256; a JVM without it cannot sign anything.
        throw SekretoError("sekreto: sigv4: no SHA-256: ${err.message}")
    }

internal fun hmac(key: ByteArray, text: String): ByteArray =
    try {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.doFinal(text.toByteArray(StandardCharsets.UTF_8))
    } catch (err: GeneralSecurityException) {
        throw SekretoError("sekreto: sigv4: no HmacSHA256: ${err.message}")
    }

/**
 * RFC 3986 escaping, which is stricter than the usual URL encoder: AWS
 * wants everything but unreserved characters escaped, with uppercase hex.
 */
internal fun uriescape(text: String): String {
    val out = StringBuilder()

    for (byte in text.toByteArray(StandardCharsets.UTF_8)) {
        val ch = byte.toInt() and 0xff
        if (('A'.code <= ch && 'Z'.code >= ch) ||
            ('a'.code <= ch && 'z'.code >= ch) ||
            ('0'.code <= ch && '9'.code >= ch) ||
            '-'.code == ch || '_'.code == ch || '.'.code == ch || '~'.code == ch
        ) {
            out.append(ch.toChar())
        } else {
            out.append('%').append("%02X".format(ch))
        }
    }

    return out.toString()
}

/** Percent-decode, and nothing else: `+` stays `+`, as on the wire. */
internal fun uridecode(text: String): String {
    val out = ByteArrayOutputStream()
    var index = 0

    while (index < text.length) {
        val head = text[index]

        if ('%' == head && index + 2 < text.length) {
            val code = text.substring(index + 1, index + 3).toIntOrNull(16)
            if (null != code) {
                out.write(code)
                index += 3
                continue
            }
            // A stray % is kept as-is, the way a browser would.
        }

        out.write(head.toString().toByteArray(StandardCharsets.UTF_8))
        index++
    }

    return String(out.toByteArray(), StandardCharsets.UTF_8)
}

/**
 * The canonical query string: each pair RFC 3986-escaped, sorted by escaped
 * key then escaped value.
 */
internal fun canonicalquery(query: String): String {
    if (query.isEmpty()) {
        return ""
    }

    return query.split("&")
        .map { pair ->
            val eq = pair.indexOf('=')
            val key = if (-1 == eq) pair else pair.substring(0, eq)
            val value = if (-1 == eq) "" else pair.substring(eq + 1)
            uriescape(uridecode(key)) to uriescape(uridecode(value))
        }
        .sortedWith(compareBy({ it.first }, { it.second }))
        .joinToString("&") { "${it.first}=${it.second}" }
}

/**
 * Sign one request. Returns the headers to attach: authorization,
 * x-amz-date, and x-amz-security-token when a session token was given, in
 * that order - the spec compares the result as a JSON object, and callers
 * print it field by field.
 */
fun sigv4(input: Signing): Map<String, String> {
    val url = URI.create(input.url)

    val date = input.datetime.substring(0, 8)
    val session = if (input.session.isNullOrEmpty()) null else input.session

    // Every header that will be signed: the caller's extras, plus host and
    // x-amz-date (and the session token when present), lower-cased and
    // trimmed the way the canonical form requires. A TreeMap keeps them
    // sorted by name, which is the canonical order.
    //
    // Canonical header values are trimmed AND internally collapsed - AWS
    // folds sequential whitespace to one space before signing, so a header
    // like "a  b" must sign as "a b" or the service refuses it.
    val headers = TreeMap<String, String>()
    for ((key, value) in input.headers) {
        headers[key.lowercase()] = value.trim().replace(Regex("\\s+"), " ")
    }
    headers["host"] = url.host + if (-1 == url.port) "" else ":${url.port}"
    headers["x-amz-date"] = input.datetime
    if (null != session) {
        headers["x-amz-security-token"] = session
    }

    val canonicalheaders = headers.entries.joinToString("") { "${it.key}:${it.value}\n" }
    val signedheaders = headers.keys.joinToString(";")

    val path = if (url.rawPath.isNullOrEmpty()) "/" else url.rawPath
    val query = url.rawQuery ?: ""

    val canonicalrequest = listOf(
        input.method.uppercase(),
        path,
        canonicalquery(query),
        canonicalheaders,
        signedheaders,
        sha256hex(input.body),
    ).joinToString("\n")

    val scope = "$date/${input.region}/${input.service}/aws4_request"

    val stringtosign = listOf(
        "AWS4-HMAC-SHA256",
        input.datetime,
        scope,
        sha256hex(canonicalrequest),
    ).joinToString("\n")

    val kdate = hmac(("AWS4" + input.secret).toByteArray(StandardCharsets.UTF_8), date)
    val kregion = hmac(kdate, input.region)
    val kservice = hmac(kregion, input.service)
    val ksigning = hmac(kservice, "aws4_request")
    val signature = hex(hmac(ksigning, stringtosign))

    val out = LinkedHashMap<String, String>()
    out["authorization"] =
        "AWS4-HMAC-SHA256 Credential=${input.keyid}/$scope" +
        ", SignedHeaders=$signedheaders" +
        ", Signature=$signature"
    out["x-amz-date"] = input.datetime

    if (null != session) {
        out["x-amz-security-token"] = session
    }

    return out
}
