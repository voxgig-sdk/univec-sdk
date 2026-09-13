// VENDORED: @voxgig/sekreto sdk-20260908-1556-0 (scala/plugins/Httpjson.scala)
// Source: https://github.com/voxgig/sekreto @ 1267ee2e5f49566bc92695bc9eb3a60ef4924998  [tag: sdk-20260911-2013-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
// The shared HTTP-JSON transport, and the child-process runner.
//
// PLUGIN-ONLY, and that is the point of the file. A socket, a TLS handshake
// and a forked process are exactly what the core does not have, so the
// bounded, redirect-refusing, one JSON round-trip helper every vault client
// here is built on lives under `plugins/` with them. A chain of the four
// built-in kinds never links it.
//
// A port of typescript/plugins/httpjson.ts, which is canonical.

package com.voxgig.sekreto.plugins

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets
import java.time.Duration

import com.voxgig.sekreto.*

/** How long any single vault round-trip may take before it is treated as
  * unreachable. Ports carry the same bound.
  */
private val TIMEOUT: Duration = Duration.ofSeconds(10)

/** How much of a response body will be read before the store is treated as
  * having answered incoherently. Ports carry the same bound.
  *
  * Far above anything real - the largest legitimate payload this library
  * fetches is Doppler's whole-config download, measured in kilobytes. A
  * bound is needed because the TIMEOUT is not one: ten seconds on a loopback
  * or datacentre link is gigabytes, and the body is accumulated in memory
  * before it is parsed. This runs on an application's startup path, so the
  * failure is the application never starting.
  */
private val MAXBODY: Int = 8 * 1024 * 1024

/** An environment variable, or None. */
private[plugins] def getenv(name: String): Option[String] = Option(System.getenv(name))

/** What a finished child process left behind. */
private[plugins] case class Ran(out: String, why: String, status: Int)

/** Run a child to completion and collect both its streams.
  *
  * The two streams are drained CONCURRENTLY. Reading stdout to EOF and only
  * then reading stderr deadlocks the moment the child writes more than one
  * pipe buffer (64 KiB on Linux) to stderr: the parent is blocked waiting
  * for stdout, the child is blocked waiting for room on stderr, and neither
  * can move. Nothing in this library sets a timeout, so that hang is
  * permanent - `get()` simply never returns. secretspec's diagnostics are
  * box-drawn and reach that size easily.
  *
  * The child's stdin is closed rather than left open on a pipe nobody writes
  * to, so a CLI that reads it - one prompting for a passphrase when its
  * environment variable is absent - sees EOF and gives up instead of waiting
  * forever.
  */
private[plugins] def runcmd(builder: ProcessBuilder, command: String): Ran =
  try
    val process = builder.start()

    process.getOutputStream.close()

    val errbuf = ByteArrayOutputStream()

    val pump: Runnable = () =>
      try process.getErrorStream.transferTo(errbuf)
      catch
        // The child went away mid-write; waitFor reports how.
        case _: IOException => ()

    val drain = Thread(pump)
    drain.setDaemon(true)
    drain.start()

    val out = String(process.getInputStream.readAllBytes, StandardCharsets.UTF_8)
    val status = process.waitFor()
    drain.join()

    Ran(out, String(errbuf.toByteArray, StandardCharsets.UTF_8).trim, status)
  catch
    case err: IOException =>
      throw SekretoError(s"sekreto: cannot run $command: ${err.getMessage}")
    case err: InterruptedException =>
      Thread.currentThread.interrupt()
      throw SekretoError(s"sekreto: interrupted running $command")

// HTTP/1.1, explicitly.
//
// java.net.http defaults to HTTP_2, and over cleartext that means an h2c
// upgrade: the first request goes out with `Upgrade: h2c`, the declared
// Content-Length, and NO BODY, and the body follows only after the server
// declines. A server that checks the two against each other - Fastify does,
// and Infisical is Fastify - rejects that request outright with "Request
// body size did not match Content-Length", so every POST this port makes to
// such a server fails before it is even read.
//
// The mocks in test/ are Node's own http module, which does not object,
// which is why this survived until the same code met a real Infisical. No
// vault API this library speaks needs HTTP/2.
//
// Redirects are never followed: a vault API does not legitimately redirect,
// and a followed redirect would carry X-Vault-Token to the redirect's host
// (and could downgrade https to http), which checkaddr - it only validates
// the configured address - cannot see.
private val CLIENT: HttpClient = HttpClient
  .newBuilder()
  .version(HttpClient.Version.HTTP_1_1)
  .followRedirects(HttpClient.Redirect.NEVER)
  .connectTimeout(TIMEOUT)
  .build()

/** One JSON round-trip's result: the status, and the parsed body. */
private[plugins] case class Answer(status: Int, body: Option[Json])

/** One JSON round-trip. Network failure is always an error - an unreachable
  * store is a store that could not answer.
  */
private[plugins] def fetchjson(
    method: String,
    url: String,
    headers: Map[String, String] = Map.empty,
    body: Option[String] = None,
): Answer =
  val builder = HttpRequest
    .newBuilder()
    .uri(URI.create(url))
    .timeout(TIMEOUT)
    .method(
      method,
      body match
        case None       => HttpRequest.BodyPublishers.noBody()
        case Some(text) => HttpRequest.BodyPublishers.ofString(text, StandardCharsets.UTF_8),
    )

  for (key, value) <- headers do builder.header(key, value)

  // ofInputStream, not ofString: ofString buffers whatever arrives, so an
  // endless body would be accumulated in memory until the deadline - which
  // on a loopback or datacentre link is gigabytes.
  val response: HttpResponse[InputStream] =
    try CLIENT.send(builder.build(), HttpResponse.BodyHandlers.ofInputStream())
    catch
      // A refused connection arrives with a null message, so the class name
      // stands in - "cannot reach ...: null" says nothing at all.
      case err: IOException =>
        throw SekretoError(s"sekreto: cannot reach ${bare(url)}: ${why(err)}")
      case err: InterruptedException =>
        Thread.currentThread.interrupt()
        throw SekretoError(s"sekreto: cannot reach ${bare(url)}: interrupted")

  // A success status promised JSON; a body that does not parse means the
  // store could not answer coherently, and treating it as a miss would fall
  // through to a weaker store. Error statuses may carry any body - they are
  // decided on status alone.
  // One byte over the bound is enough to know it was exceeded. An endless
  // body is a store that could not answer, so this raises rather than
  // returning a miss - the latter would fall through to a weaker store on an
  // attacker's cue.
  val stream = response.body()
  val text =
    try
      val raw = stream.readNBytes(MAXBODY + 1)
      if MAXBODY < raw.length then
        throw SekretoError(s"sekreto: oversized response from ${bare(url)}")
      String(raw, StandardCharsets.UTF_8)
    catch
      case err: IOException =>
        throw SekretoError(s"sekreto: cannot reach ${bare(url)}: ${why(err)}")
    finally stream.close()

  val parsed = Json.parse(text)
  if 200 == response.statusCode() && parsed.isEmpty then
    throw SekretoError(s"sekreto: malformed response from ${bare(url)}")

  Answer(response.statusCode(), parsed)

/** What an exception has to say for itself, never the empty string. */
private def why(err: Throwable): String = Option(err.getMessage).getOrElse(err.toString)

/** A URL without its query string, for a message that must not leak one. */
private[plugins] def bare(url: String): String = url.takeWhile(_ != '?')

/** The first candidate that is set and non-empty, or empty. */
private[plugins] def first(candidates: Option[String]*): String =
  candidates.iterator.flatten.find(_.nonEmpty).getOrElse("")

private[plugins] def trimslash(text: String): String = dropsuffix(text, "/")

/** When a logged-in token must be renewed, from its expiry in seconds (a
  * JSON number, or a string as Azure IMDS sends it): now + max(seconds - 60,
  * 1). A missing or zero expiry means never renew.
  */
private[plugins] def renewtime(expires: Option[Json]): Long =
  val seconds = expires match
    case Some(Json.Num(value)) => value
    case Some(Json.Str(value)) => value.toDoubleOption.getOrElse(0.0)
    case _                     => 0.0

  if seconds.isNaN || 0 >= seconds then Long.MaxValue
  else System.currentTimeMillis + (math.max(seconds - 60, 1.0) * 1000).toLong
