// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (kotlin/plugins/Httpjson.kt)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The shared HTTP-JSON transport, and the child-process runner.
//
// PLUGIN-ONLY, and that is the point of the file. A socket, a TLS
// handshake and a forked process are exactly what the core does not
// have, so the bounded, redirect-refusing, one JSON round-trip helper
// every vault client here is built on lives under `plugins/` with them.
// A chain of the four built-in kinds never links it.
//
// A port of typescript/plugins/httpjson.ts, which is canonical.

package KOTLINPACKAGE.feature.secrets.sekreto.plugins

import KOTLINPACKAGE.feature.secrets.sekreto.Json
import KOTLINPACKAGE.feature.secrets.sekreto.SekretoError

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets
import java.time.Duration

/** How long any single vault round-trip may take before it is treated
 * as unreachable. Ports carry the same bound. */
private val TIMEOUT: Duration = Duration.ofSeconds(10)

/**
 * How much of a response body will be read before the store is treated
 * as having answered incoherently. Ports carry the same bound.
 *
 * Far above anything real - the largest legitimate payload this library
 * fetches is Doppler's whole-config download, measured in kilobytes. A
 * bound is needed because the TIMEOUT is not one: ten seconds on a
 * loopback or datacentre link is gigabytes, and the body is accumulated
 * in memory before it is parsed. This runs on an application's startup
 * path, so the failure is the application never starting.
 */
private const val MAXBODY = 8 * 1024 * 1024

/** What a finished child process left behind. */
internal data class Ran(val out: String, val why: String, val status: Int)

/**
 * Run a child to completion and collect both its streams.
 *
 * The two streams are drained CONCURRENTLY. Reading stdout to EOF and
 * only then reading stderr deadlocks the moment the child writes more
 * than one pipe buffer (64 KiB on Linux) to stderr: the parent is blocked
 * waiting for stdout, the child is blocked waiting for room on stderr,
 * and neither can move. Nothing in this library sets a timeout, so that
 * hang is permanent - `get()` simply never returns. secretspec's
 * diagnostics are box-drawn and reach that size easily.
 *
 * The child's stdin is closed rather than left open on a pipe nobody
 * writes to, so a CLI that reads it - one prompting for a passphrase when
 * its environment variable is absent - sees EOF and gives up instead of
 * waiting forever.
 */
internal fun runcmd(builder: ProcessBuilder, command: String): Ran {
    try {
        val process = builder.start()

        process.outputStream.close()

        val errbuf = ByteArrayOutputStream()
        val drain = Thread {
            try {
                process.errorStream.transferTo(errbuf)
            } catch (err: IOException) {
                // The child went away mid-write; waitFor reports how.
            }
        }
        drain.isDaemon = true
        drain.start()

        val out = String(process.inputStream.readAllBytes(), StandardCharsets.UTF_8)
        val status = process.waitFor()
        drain.join()

        return Ran(out, String(errbuf.toByteArray(), StandardCharsets.UTF_8).trim(), status)
    } catch (err: IOException) {
        throw SekretoError("sekreto: cannot run $command: ${err.message}")
    } catch (err: InterruptedException) {
        Thread.currentThread().interrupt()
        throw SekretoError("sekreto: interrupted running $command")
    }
}

// HTTP/1.1, explicitly.
//
// java.net.http defaults to HTTP_2, and over cleartext that means an h2c
// upgrade: the first request goes out with `Upgrade: h2c`, the declared
// Content-Length, and NO BODY, and the body follows only after the
// server declines. A server that checks the two against each other -
// Fastify does, and Infisical is Fastify - rejects that request outright
// with "Request body size did not match Content-Length", so every POST
// this port makes to such a server fails before it is even read.
//
// The mocks in test/ are Node's own http module, which does not object,
// which is why this survived until the same code met a real Infisical.
// No vault API this library speaks needs HTTP/2.
//
// Redirects are never followed: a vault API does not legitimately
// redirect, and a followed redirect would carry X-Vault-Token to the
// redirect's host (and could downgrade https to http), which checkaddr -
// it only validates the configured address - cannot see.
private val CLIENT: HttpClient = HttpClient.newBuilder()
    .version(HttpClient.Version.HTTP_1_1)
    .followRedirects(HttpClient.Redirect.NEVER)
    .connectTimeout(TIMEOUT)
    .build()

/** One JSON round-trip's result: the status, and the parsed body. */
internal data class Answer(val status: Int, val body: Json?)

/**
 * One JSON round-trip. Network failure is always an error - an
 * unreachable store is a store that could not answer.
 */
internal fun fetchjson(
    method: String,
    url: String,
    headers: Map<String, String> = emptyMap(),
    body: String? = null,
): Answer {
    val builder = HttpRequest.newBuilder()
        .uri(URI.create(url))
        .timeout(TIMEOUT)
        .method(
            method,
            if (null == body) {
                HttpRequest.BodyPublishers.noBody()
            } else {
                HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8)
            },
        )

    for ((key, value) in headers) {
        builder.header(key, value)
    }

    // ofInputStream, not ofString: ofString buffers whatever arrives, so
    // an endless body would be accumulated in memory until the deadline -
    // which on a loopback or datacentre link is gigabytes.
    val response: HttpResponse<java.io.InputStream> = try {
        CLIENT.send(builder.build(), HttpResponse.BodyHandlers.ofInputStream())
    } catch (err: IOException) {
        // A refused connection arrives with a null message, so the class
        // name stands in - "cannot reach ...: null" says nothing at all.
        throw SekretoError(
            "sekreto: cannot reach ${bare(url)}: ${err.message ?: err.toString()}",
        )
    } catch (err: InterruptedException) {
        Thread.currentThread().interrupt()
        throw SekretoError("sekreto: cannot reach ${bare(url)}: interrupted")
    }

    // A success status promised JSON; a body that does not parse means
    // the store could not answer coherently, and treating it as a miss
    // would fall through to a weaker store. Error statuses may carry any
    // body - they are decided on status alone.
    // One byte over the bound is enough to know it was exceeded. An
    // endless body is a store that could not answer, so this raises
    // rather than returning a miss - the latter would fall through to a
    // weaker store on an attacker's cue.
    val text = try {
        response.body().use { stream ->
            val raw = stream.readNBytes(MAXBODY + 1)
            if (MAXBODY < raw.size) {
                throw SekretoError("sekreto: oversized response from ${bare(url)}")
            }
            String(raw, StandardCharsets.UTF_8)
        }
    } catch (err: IOException) {
        throw SekretoError(
            "sekreto: cannot reach ${bare(url)}: ${err.message ?: err.toString()}",
        )
    }

    val parsed = Json.parse(text)
    if (200 == response.statusCode() && null == parsed) {
        throw SekretoError("sekreto: malformed response from ${bare(url)}")
    }

    return Answer(response.statusCode(), parsed)
}

/** A URL without its query string, for a message that must not leak one. */
internal fun bare(url: String): String = url.substringBefore('?')

/** The first candidate that is set and non-empty, or empty. */
internal fun first(vararg candidates: String?): String =
    candidates.firstOrNull { !it.isNullOrEmpty() } ?: ""

internal fun trimslash(text: String): String = text.removeSuffix("/")

/**
 * When a logged-in token must be renewed, from its expiry in seconds (a
 * JSON number, or a string as Azure IMDS sends it): now + max(seconds -
 * 60, 1). A missing or zero expiry means never renew.
 */
internal fun renewtime(expires: Json?): Long {
    val seconds = when (expires) {
        is Json.Num -> expires.value
        is Json.Str -> expires.value.toDoubleOrNull() ?: 0.0
        else -> 0.0
    }

    if (seconds.isNaN() || 0 >= seconds) {
        return Long.MAX_VALUE
    }

    return System.currentTimeMillis() + (maxOf(seconds - 60, 1.0) * 1000).toLong()
}
