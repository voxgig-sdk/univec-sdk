// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Aws.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The two AWS stores, as voxgig/plugin definitions.
//
// One file, because they share the SigV4 request signing and the
// credential resolution in this file and nothing else does.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Definition
import KOTLINPACKAGE.feature.secrets.sekreto.Json
import KOTLINPACKAGE.feature.secrets.sekreto.Provider
import KOTLINPACKAGE.feature.secrets.sekreto.Providers.checkaddr
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError
import KOTLINPACKAGE.feature.secrets.sekreto.awsparam
import KOTLINPACKAGE.feature.secrets.sekreto.providerplugin
import KOTLINPACKAGE.feature.secrets.sekreto.vaultref

import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Base64

/** The `YYYYMMDDTHHMMSSZ` timestamp SigV4 wants, for now. */
internal fun awsnow(): String =
    DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'")
        .withZone(ZoneOffset.UTC)
        .format(Instant.now())

/** Region and credentials, resolved for one call. */
internal data class Awsauth(
    val region: String,
    val keyid: String,
    val secret: String,
    val session: String?,
)

/**
 * Region and credentials, from config first and the standard AWS_*
 * environment variables second - those are AWS's own convention, and a
 * pod or CI job that has them set should just work. Missing either is an
 * error: an AWS store with no credentials could not answer.
 */
internal fun awsauth(
    region: String?,
    keyid: String?,
    secret: String?,
    session: String?,
): Awsauth {
    val useregion =
        first(region, System.getenv("AWS_REGION"), System.getenv("AWS_DEFAULT_REGION"))
    val usekeyid = first(keyid, System.getenv("AWS_ACCESS_KEY_ID"))
    val usesecret = first(secret, System.getenv("AWS_SECRET_ACCESS_KEY"))
    val usesession = first(session, System.getenv("AWS_SESSION_TOKEN"))

    if (useregion.isEmpty()) {
        throw SekretoError("sekreto: aws: no region (set region or AWS_REGION)")
    }
    if (usekeyid.isEmpty() || usesecret.isEmpty()) {
        throw SekretoError(
            "sekreto: aws: no credentials" +
                " (set keyid/secret or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY)",
        )
    }

    return Awsauth(useregion, usekeyid, usesecret, usesession.ifEmpty { null })
}

/** One signed call to an AWS JSON-1.1 API. */
internal fun awscall(
    region: String?,
    keyid: String?,
    secret: String?,
    session: String?,
    addr: String?,
    service: String,
    target: String,
    payload: String,
): Answer {
    val auth = awsauth(region, keyid, secret, session)

    // The China partition lives under its own suffix; every other
    // commercial region is plain amazonaws.com.
    val suffix =
        if (auth.region.startsWith("cn-")) ".amazonaws.com.cn" else ".amazonaws.com"
    val useaddr = first(addr, "https://$service.${auth.region}$suffix")
    checkaddr(useaddr)

    val url = trimslash(useaddr) + "/"

    val extras = linkedMapOf(
        "content-type" to "application/x-amz-json-1.1",
        "x-amz-target" to target,
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

    return fetchjson("POST", url, extras + signed, payload)
}

/**
 * Does this AWS error body name one of the not-found types? Those are a
 * miss; every other failure is a store that could not answer.
 */
internal fun awsmiss(body: Json?, vararg types: String): Boolean {
    val errtype = body?.dig("__type")?.asstr ?: return false
    return types.any { errtype.contains(it) }
}

/**
 * AWS Secrets Manager.
 *
 * `api.token` reads the secret named `api` (the vaultref path, so
 * `db.pass.main` reads `db/pass`) and takes the `token` field of its JSON
 * SecretString - the AWS idiom of one JSON map per secret. A SecretString
 * that is not JSON is the value itself, under the conventional field
 * `value`. Requests are SigV4-signed in-tree; see Sigv4.kt.
 */
class Awssecrets(
    private val region: String? = null,
    private val keyid: String? = null,
    private val secret: String? = null,
    private val session: String? = null,
    private val addr: String? = null,
) : Provider {

    override fun lookup(name: String): String? {
        val ref = vaultref(name)

        val res = awscall(
            region, keyid, secret, session, addr,
            "secretsmanager", "secretsmanager.GetSecretValue",
            Json.stringify(Json.obj("SecretId" to Json.str(ref.path))),
        )

        if (400 == res.status && awsmiss(res.body, "ResourceNotFoundException")) {
            return null
        }

        if (200 != res.status) {
            throw SekretoError("sekreto: aws secretsmanager error: ${res.status}")
        }

        val text = res.body?.dig("SecretString")?.asstr

        if (null == text) {
            // A binary secret has no fields to address; only the
            // conventional `value` field can mean "the bytes themselves".
            val bin = res.body?.dig("SecretBinary")?.asstr
            if (null != bin && "value" == ref.field) {
                // decode() throws IllegalArgumentException on a bad
                // payload, which is not a SekretoError and so escaped
                // the library's own error type. A store that answered
                // incoherently is an error.
                return try {
                    String(Base64.getDecoder().decode(bin), StandardCharsets.UTF_8)
                } catch (err: IllegalArgumentException) {
                    throw SekretoError("sekreto: aws secretsmanager: undecodable secret")
                }
            }
            return null
        }

        val parsed = Json.parse(text)

        if (parsed is Json.Obj) {
            return parsed.value[ref.field]?.text
        }

        // A plain-string secret is the whole value; it has no named fields.
        return if ("value" == ref.field) text else null
    }

    // Config only, never the environment: describe() feeds the spec's
    // sources group, which must answer the same everywhere.
    override fun describe(): String = "awssecrets:${region ?: ""}"
}

/**
 * AWS SSM Parameter Store.
 *
 * `db.pass.main` reads the parameter `/db/pass/main` (under an optional
 * prefix path), decrypted. Parameter Store carries flat strings, so there
 * is no field indirection.
 */
class Awsparams(
    private val region: String? = null,
    private val keyid: String? = null,
    private val secret: String? = null,
    private val session: String? = null,
    private val addr: String? = null,
    private val prefix: String? = null,
) : Provider {

    override fun lookup(name: String): String? {
        val payload = Json.obj(
            "Name" to Json.str(awsparam(name, prefix)),
            "WithDecryption" to Json.bool(true),
        )

        val res = awscall(
            region, keyid, secret, session, addr,
            "ssm", "AmazonSSM.GetParameter", Json.stringify(payload),
        )

        if (400 == res.status && awsmiss(res.body, "ParameterNotFound")) {
            return null
        }

        if (200 != res.status) {
            throw SekretoError("sekreto: aws ssm error: ${res.status}")
        }

        return res.body?.dig("Parameter", "Value")?.text
    }

    override fun describe(): String = "awsparams:${region ?: ""}${prefix ?: ""}"
}

/** The `awssecrets` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `awssecrets` chain entry. */
val awssecrets: Definition = providerplugin("awssecrets") { spec ->
    Awssecrets(
        spec.region, spec.keyid, spec.secret, spec.session, spec.addr,
    )
}

/** The `awsparams` provider kind, as a voxgig/plugin definition. A
 * consumer imports this and hands it to `Sekreto`; a consumer that does
 * not is a `Sekreto` that cannot build a `awsparams` chain entry. */
val awsparams: Definition = providerplugin("awsparams") { spec ->
    Awsparams(
        spec.region, spec.keyid, spec.secret, spec.session, spec.addr, spec.prefix,
    )
}
